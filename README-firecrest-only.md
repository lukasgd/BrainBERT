# FirecREST orchestration of BrainBERT pre-training

Set up a new working directory on a client machine as follows:

```bash
mkdir local-storage
```

## Obtain data and code on the client

Download braintreebank.dev data to the local storage

```bash
cd local-storage
wget -r -np -nH --cut-dirs=1 -R "index.html*" https://braintreebank.dev/data/
```

Optionally, download pretrained weights from the Google Drive link as detailed in Readme to `local-storage/`.

Clone the BrainBERT repository and download dependencies for building the eventual container image on the desired target platform with

```bash
git clone git@github.com:lukasgd/BrainBERT.git && cd BrainBERT
env/podman_build.sh --prepare-offline --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
```

This will build the first stage (download) in `env/Dockerfile.prod-multistage`, containing all dependencies necessary to build the final image (under `/workspace/build_deps` and `/workspace/BrainBERT`).

If you try to run the above step on an `x86_64` machine with Ubuntu, you may first need to `apt install qemu-user-static` to emulate the target architecture. This step took ~23 min on an x86 test machine. 

On a machine with docker installed (analogous for podman), the above will evaluate to

```bash
docker build --target download --platform linux/arm64 -t localhost/${USER}/ngc-brainbert:25.06-download -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
docker save --platform linux/arm64 -o build_deps/images/localhost-${USER}-ngc-brainbert+25.06-download-linux-arm64.tar localhost/${USER}/ngc-brainbert:25.06-download
```

In the same directory, also build a local environment for monitoring with MLflow and interacting with remote HPC clusters through FirecREST, e.g. a Python virtual environment

```bash
(cd .. && \
    python -m venv --system-site-packages local-venv && \
    . local-venv/bin/activate && \
    pip install mlflow pyfirecrest)
```

or a container

```bash
env/podman_build.sh ngc-brainbert:25.06 -f env/Dockerfile.prod --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
```

and change back to the root directory afterwards

```bash
cd ../..
```

## Set up the FirecREST client

In order to transfer data and submit jobs to Clariden, set up [PyFirecREST](https://pyfirecrest.readthedocs.io/). This is a client package for [FirecREST](https://eth-cscs.github.io/firecrest-v2/openapi), which is a REST API to interface with Alps. Follow the instructions at https://docs.cscs.ch/access/firecrest/ and create an application `brainbert` on the [developer portal](https://docs.cscs.ch/services/devportal/) [https://developer.cscs.ch]() that is subscribed to the `FirecREST-ML - v2` API to use it in the following.

After some initialization, the client is ready to submit jobs and launch data transfers on Clariden. For the rest of this workflow, we assume that on the client machine the user name for Clariden is captured in `${FIRECREST_USER}` and the account in `${FIRECREST_ACCOUNT}` (consistent with `firecrest id -s clariden`). Since we are only targeting the Clariden system, we will additionally set `${FIRECREST_SYSTEM}` to `clariden` on the client. Finally, we choose a path in `${FIRECREST_WORKDIR}` that serves as a base directory for all data generated during this workflow. A typical choice can be under `${SCRATCH}`. The overall configuration then looks like

```bash
export FIRECREST_USER=...
export FIRECREST_ACCOUNT=...
export FIRECREST_SYSTEM="clariden"
export FIRECREST_WORKDIR="/iopsstor/scratch/cscs/${FIRECREST_USER:?}/test-brainbert"
```

An example job submission then looks as

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

# submit job and wait for its completion
build_job = client.submit(
    account=os.environ['FIRECREST_ACCOUNT'],
    working_dir=f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT",
    script_local_path=f"BrainBERT/slurm/submit-env.sh")
print(build_job)

client.wait_for_job(
    job_id=build_job.get("jobId")
)
```

This can be run inside the `local-venv` or the local container created previously with PyFirecREST installed, in the latter case run e.g.

```bash
docker run -it --rm -v $(pwd):$(pwd) -w $(pwd) ngc-brainbert:25.06
```

Alternatively to the Python script, you can directly use PyFirecREST's CLI, `firecrest`. This requires the additional configuration

```bash
export FIRECREST_CLIENT_ID="..."
export FIRECREST_CLIENT_SECRET="..."
export AUTH_TOKEN_URL="https://auth.cscs.ch/auth/realms/firecrest-clients/protocol/openid-connect/token"
export FIRECREST_URL="https://api.cscs.ch/ml/firecrest/v2
```

To create a new directory `${FIRECREST_WORKDIR}` on Clariden, run

```bash
firecrest mkdir -p \
    ${FIRECREST_WORKDIR:?}/BrainBERT
```

If the remote storage system is based on LUSTRE, it is assumed that [good striping defaults](https://docs.cscs.ch/guides/storage/#sharing-files-and-data) are pre-configured. Otherwise, they must be applied before transferring any data/code. For this, source the utilities for FirecREST in the `slurm` directory in your shell environment,

```bash
source slurm/firecrest-cli-utils.sh
```

and execute the following code to submit a job that sets these settings

```bash
# submit job (only job-specific parts are in this command)
f7t_job=$(firecrest submit \
    --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
    --env-var FIRECREST_WORKDIR=${FIRECREST_WORKDIR:?} \
    "BrainBERT/slurm/submit-lfs-setstripe.sh")

firecrest_job_wait_and_extract_status "${f7t_job}"
```

The last line ensures that the job completes before control is returned to the user (i.e. synchronous execution) and checks for possible errors. It also sets the job-related variables `f7t_job_id`, `f7t_job_name`, `f7t_job_state` and `f7t_job_exit_code` in the current shell for easy access in subsequent utility calls.

To retrieve the stdout, use the command 

```bash
firecrest_job_stdout_path <job-name> <job-id>
```

or just without arguments if for the same job as the latest invocation of `firecrest_job_wait_and_extract_status`. To continuously monitor the output, use analogously

```bash
firecrest_job_tail_stdout <job-name> <job-id>
```

and to download the stdout after job completion, use

```bash
firecrest_job_download_stdout <job-name> <job-id>
```

again with the same defaults if arguments are omitted. Jobs generally redirect stderr to stdout, but if for some reason they would be managed separately, analogous techniques could be implemented for stderr.

## Transfer data to remote storage

Now, copy the pretraining dataset (and optionally weights) to remote storage via

```bash
tar -cvf braintreebank.dev.tar -C local-storage braintreebank.dev
firecrest --debug upload \
    --account ${FIRECREST_ACCOUNT:?} \
    braintreebank.dev.tar ${FIRECREST_WORKDIR:?} braintreebank.dev.tar
```

This takes ~24 mins for 12 GB (~8 % of the pretraining dataset) over a VPN connection.

Likewise for the download container image stage containing the base image and all dependencies (~45 mins transfer), plus the build files as in

```bash
firecrest_batch_upload BrainBERT/{env/Dockerfile.prod-multistage,env/podman_build.sh,env/ngc-brainbert-25.06.toml,.dockerignore,build_deps/images/localhost-${FIRECREST_USER:?}-ngc-brainbert+25.06-download-linux-arm64.tar}
```

## Finish building the container on the remote

The container build can be completed on Clariden with

```bash
cd /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT
sbatch slurm/submit-build-image-offline.sh
```

which on a compute node evaluates to

```bash
podman load -i build_deps/images/localhost-${USER}-ngc-brainbert+25.06-download-linux-arm64.tar
podman build --network none --build-arg DOWNLOAD_IMAGE=localhost/${USER}/ngc-brainbert:25.06-download --platform linux/arm64 -t localhost/${USER}/ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
enroot import -x mount -o /capstor/scratch/cscs/${USER}/images/ngc-brainbert+25.06.sqsh podman://localhost/${USER}/ngc-brainbert:25.06
```

Alternatively, the built image can also be saved from podman as a tar file and retrieved locally (e.g. to be hosted on an external container registry).

All of this can be run through [PyFirecREST](https://pyfirecrest.readthedocs.io/)'s CLI with

```bash
f7t_build_job=$(firecrest submit \
    --account ${FIRECREST_ACCOUNT:?} \
    --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
    BrainBERT/slurm/submit-build-image-offline.sh)

firecrest_job_wait_and_extract_status "${f7t_build_job}"
```

> **TODO:** Address `podman load -i` error when invoked through FirecREST.

## Run BrainBERT pretraining

### Data preparation

Preprocess and extract the pre-training data as detailed in [Readme](https://github.com/lukasgd/BrainBERT?tab=readme-ov-file#brainbert-pre-training-data) using

```bash
PRETRAIN_DATA_RAW_DIR=${FIRECREST_WORKDIR:?}/braintreebank.dev \
    sbatch --wait slurm/submit-extract-raw.sh
PRETRAIN_DATA_RAW_DIR=${FIRECREST_WORKDIR:?}/braintreebank.dev \
PRETRAIN_DATA_DIR=${FIRECREST_WORKDIR:?}/pretrain_data \
HYDRA_BASE_RUN_DIR=${FIRECREST_WORKDIR:?}/BrainBERT/outputs \
    sbatch slurm/submit-preprocess-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
extract_raw_job = client.submit(
    account=os.environ['FIRECREST_ACCOUNT'],
    working_dir=f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT",
    env_vars={ "PRETRAIN_DATA_RAW_DIR": f"{os.environ['FIRECREST_WORKDIR']}/braintreebank.dev" },
    script_local_path="/BrainBERT/slurm/submit-extract-raw.sh")
print(extract_raw_job)

client.wait_for_job(
    job_id=extract_raw_job.get("jobId")
)

preprocess_job = client.submit(
    account=os.environ['FIRECREST_ACCOUNT'],
    working_dir=f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT",
    env_vars={ "PRETRAIN_DATA_RAW_DIR": f"{os.environ['FIRECREST_WORKDIR']}/braintreebank.dev",
               "PRETRAIN_DATA_DIR": f"{os.environ['FIRECREST_WORKDIR']}/pretrain_data",
               "HYDRA_BASE_RUN_DIR": f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT/outputs"
 },
    script_local_path="BrainBERT/slurm/submit-preprocess-prod.sh")
print(preprocess_job)

client.wait_for_job(
    job_id=preprocess_job.get("jobId")
)
```

or via CLI

```bash
f7t_extract_job=$(firecrest submit \
    --account ${FIRECREST_ACCOUNT:?} \
    --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
    --env-var PRETRAIN_DATA_RAW_DIR=${FIRECREST_WORKDIR:?}/braintreebank.dev \
    BrainBERT/slurm/submit-extract-raw.sh)

firecrest_job_wait_and_extract_status "${f7t_extract_job}"

f7t_preprocess_job=$(firecrest submit \
    --account ${FIRECREST_ACCOUNT:?} \
    --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
    --env-var PRETRAIN_DATA_RAW_DIR=${FIRECREST_WORKDIR:?}/braintreebank.dev \
    --env-var PRETRAIN_DATA_DIR=${FIRECREST_WORKDIR:?}/pretrain_data \
    --env-var HYDRA_BASE_RUN_DIR=${FIRECREST_WORKDIR:?}/BrainBERT/outputs \
    BrainBERT/slurm/submit-preprocess-prod.sh)

firecrest_job_wait_and_extract_status "${f7t_preprocess_job}"
```

### Submit pretraining job and monitor progress

Submit a training job via

```bash
PRETRAIN_DATA_DIR=${FIRECREST_WORKDIR:?}/pretrain_data \
HYDRA_BASE_RUN_DIR=${FIRECREST_WORKDIR:?}/BrainBERT/outputs \
sbatch slurm/submit-train-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
train_job = client.submit(
    account=os.environ['FIRECREST_ACCOUNT'],
    working_dir=f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT",
    env_vars={ "PRETRAIN_DATA_DIR": f"{os.environ['FIRECREST_WORKDIR']}/pretrain_data",
               "HYDRA_BASE_RUN_DIR": f"{os.environ['FIRECREST_WORKDIR']}/BrainBERT/outputs" },
    script_local_path="BrainBERT/slurm/submit-train-prod.sh")
print(train_job)

client.wait_for_job(
    job_id=train_job.get("jobId")
)
```

or via CLI

```bash
f7t_train_job=$(firecrest submit \
    --account ${FIRECREST_ACCOUNT:?} \
    --working-dir ${FIRECREST_WORKDIR:?}/BrainBERT \
    --env-var PRETRAIN_DATA_DIR=${FIRECREST_WORKDIR:?}/pretrain_data \
    --env-var HYDRA_BASE_RUN_DIR=${FIRECREST_WORKDIR:?}/BrainBERT/outputs \
    BrainBERT/slurm/submit-train-prod.sh)

firecrest_job_wait_and_extract_status "${f7t_train_job}"
```

> **TODO:** Synchronize `${FIRECREST_WORKDIR:?}/BrainBERT/outputs/YY-MM-DD/HH-MM-SS` (and possibly `mlruns`) to local storage under `BrainBERT/outputs` (identical directory structure).

Monitor training progress in the `local-venv` or locally built container by running a local MLflow instance

```bash
cd BrainBERT/outputs && mlflow ui
```

and inspect the results at `http://127.0.0.1:5000/`.

### Inspect results upon completion

Upon completion, the saved checkpoints can be accessed under `outputs/YY-MM-DD/HH-MM-SS` as `checkpoint_best.pth` as well as `checkpoint_last.pth`.
