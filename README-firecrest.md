# FirecREST orchestration of BrainBERT pre-training

Set up a new working directory on a client machine as follows:

```bash
mkdir local-storage
mkdir remote-storage
```

Mirror remote storage via `sshfs`:

```bash
sshfs clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert remote-storage
```

We're assuming here that `${USER}` is the same on the local and remote machine, otherwise adapt the remote paths.

## Obtain data and code on the client

Download braintreebank.dev data to the local storage

```bash
cd local-storage
wget -r -np -nH --cut-dirs=1 -R "index.html*" https://braintreebank.dev/data/
```

Optionally, download pretrained weights from the Google Drive link as detailed in Readme to `local-storage/`.

Clone the BrainBERT repository and prepare dependencies for building a container image on the desired target platform

```bash
git clone git@github.com:lukasgd/BrainBERT.git && cd BrainBERT
env/podman_build.sh --prepare-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod
```

If you try to run this step on an `x86_64` machine with Ubuntu, you may first need to `apt install qemu-user-static` to emulate the target architecture.

In the same directory, also build a local environment for monitoring with MLflow and interacting with remote HPC clusters through FirecREST, e.g. a Python virtual environment

```bash
(cd .. &&
    python -m venv --system-site-packages local-venv && \
    . local-venv/bin/activate && \
    pip install mlflow pyfirecrest)
```

or a container

```bash
env/podman_build.sh --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod .
```

and change back to the root directory afterwards

```bash
cd ../..
```

## Transfer data to remote storage

Copy both pretraining dataset and (optionally) weights to remote storage via

```bash
cp -r local-storage/{braintreeban.dev,pretrained_weights.zip} remote-storage/
```

Likewise for the code and container dependencies

```bash
cp -r local-storage/BrainBERT remote-storage/
```

This step may be sped up by using `scp` directly, i.e.

```bash
tar -cvf -C local-storage brainbert.tar BrainBERT
scp local-storage/brainbert.tar clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert
ssh clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert tar -xvf brainbert.tar
```

or `firecrest upload` (cf. below).

## Finish building the container on the remote

The container build can be completed with

```bash
cd /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT
sbatch slurm/submit-build-image-offline.sh
```

This can be achieved through [PyFirecREST](https://pyfirecrest.readthedocs.io/). This is a client package for [FirecREST](https://eth-cscs.github.io/firecrest-v2/openapi), which is a REST API to interface with Alps. Follow the instructions at https://docs.cscs.ch/access/firecrest/ and create an application `brainbert` on the [developer portal](https://docs.cscs.ch/services/devportal/) [https://developer.cscs.ch]() that is subscribed to the `FirecREST-ML - v2` API to use it in the following. After some initialization, the client is ready to submit jobs and launch data transfers on Clariden.

```python
import json
import firecrest as f7t

# initialize PyFirecREST
client_id = "..."
client_secret = "..."
token_uri = "https://auth.cscs.ch/auth/realms/firecrest-clients/protocol/openid-connect/token"

client = f7t.v2.Firecrest(
    firecrest_url="https://api.cscs.ch/ml/firecrest/v2",
    authorization=f7t.ClientCredentialsAuth(client_id, client_secret, token_uri)
)

# submit job
build_job = client.submit(
    system_name="clariden",
    working_dir=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT",
    account="a-csstaff",
    script_remote_path=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT/slurm/submit-build-image-offline.sh")
print(build_job)

client.wait_for_job(
    system_name="clariden",
    job_id=build_job.get("jobId")
)
```

This can be run inside the `local-venv` or the local container created previously with PyFirecREST installed, in the latter case run e.g.

```bash
docker run -it --rm -v $(pwd):$(pwd) -w $(pwd) ngc-brainbert:25.06
```

Alternatively to the Python script, you can directly use PyFirecREST's CLI. First, set the configuration

```bash
export FIRECREST_CLIENT_ID="..."
export FIRECREST_CLIENT_SECRET="..."
export AUTH_TOKEN_URL="https://auth.cscs.ch/auth/realms/firecrest-clients/protocol/openid-connect/token"
export FIRECREST_URL="https://api.cscs.ch/ml/firecrest/v2
```

and then submit a job with the same parameters (drop `remote://` to upload a local copy of the job submission script instead)

```bash
f7t_build_job=$(firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-build-image-offline.sh)

firecrest wait-for-job --system clariden $(echo $f7t_build_job  | jq .jobId)
```

The last line ensures that the job completes before control is returned to the user (i.e. synchronous execution). An error check may be added by piping its output to `jq -e '.[0].status.exitCode == "0"'`

## Run BrainBERT pretraining

### Data preparation

Preprocess and extract the pre-training data as detailed in [Readme](https://github.com/lukasgd/BrainBERT?tab=readme-ov-file#brainbert-pre-training-data) using

```bash
PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
    sbatch --wait slurm/submit-extract-raw.sh
PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
PRETRAIN_DATA_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/pretrain_data \
    sbatch slurm/submit-preprocess-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
extract_raw_job = client.submit(
    system_name="clariden",
    working_dir=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT",
    account="a-csstaff",
    env_vars={ "PRETRAIN_DATA_RAW_DIR": f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/braintreebank.dev" },
    script_remote_path=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT/slurm/submit-extract-raw.sh")
print(extract_raw_job)

client.wait_for_job(
    system_name="clariden",
    job_id=extract_raw_job.get("jobId")
)

preprocess_job = client.submit(
    system_name="clariden",
    working_dir=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT",
    account="a-csstaff",
    env_vars={ "PRETRAIN_DATA_RAW_DIR": f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/braintreebank.dev",
               "PRETRAIN_DATA_DIR": f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/pretrain_data" },
    script_remote_path=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT/slurm/submit-preprocess-prod.sh")
print(preprocess_job)

client.wait_for_job(
    system_name="clariden",
    job_id=preprocess_job.get("jobId")
)
```

or via CLI

```bash
f7t_extract_job=$(firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    --env-var PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-extract-raw.sh)

firecrest wait-for-job --system clariden $(echo $f7t_extract_job  | jq .jobId)

f7t_preprocess_job=$(firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    --env-var PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
    --env-var PRETRAIN_DATA_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/pretrain_data \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-preprocess-prod.sh)

firecrest wait-for-job --system clariden $(echo $f7t_preprocess_job  | jq .jobId)
```

### Submit pretraining job and monitor progress

Submit a training job via

```bash
PRETRAIN_DATA_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/pretrain_data \
HYDRA_BASE_RUN_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/outputs \
sbatch slurm/submit-train-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
train_job = client.submit(
    system_name="clariden",
    working_dir=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT",
    account="a-csstaff",
    env_vars={ "PRETRAIN_DATA_DIR": f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/pretrain_data",
               "HYDRA_BASE_RUN_DIR": f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT/outputs" },
    script_remote_path=f"/iopsstor/scratch/cscs/{os.environ['USER']}/test-brainbert/BrainBERT/slurm/submit-train-prod.sh")
print(train_job)

client.wait_for_job(
    system_name="clariden",
    job_id=train_job.get("jobId")
)
```

or via CLI

```bash
f7t_train_job=$(firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    --env-var PRETRAIN_DATA_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/pretrain_data \
    --env-var HYDRA_BASE_RUN_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/outputs \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-train-prod.sh)

firecrest wait-for-job --system clariden $(echo $f7t_train_job  | jq .jobId)
```

Monitor training progress in the `local-venv` or locally built container by running a local MLflow instance

```bash
cd remote-storage/BrainBERT/outputs && mlflow ui
```

and inspect the results at `http://127.0.0.1:5000/`.

### Fetch results upon completion

Upon completion, the saved checkpoints can be accessed under `outputs/YY-MM-DD/HH-MM-SS` as `checkpoint_best.pth` as well as `checkpoint_last.pth` and synchronized back to local storage,

```bash
cp -r remote-storage/BrainBERT/outputs/YY-MM-DD/HH-MM-SS local-storage/
```

Once completed, the remote storage can be unmounted

```bash
umount remote-storage
```
