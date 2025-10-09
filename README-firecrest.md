# FirecREST orchestration of BrainBERT pre-training

Set up a new working directory on a client machine as follows:

```bash
mkdir local-storage
mkdir remote-storage
```

Mirror remote storage via `sshfs`:

```bash
mkdir scratch
sshfs clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert remote-storage
```

## Obtain data and code on the client

Download braintreebank.dev data to the local storage

```bash
cd local-storage
wget -r -np -nH --cut-dirs=1 -R "index.html*" https://braintreebank.dev/data/
```

Likewise download pretrained weights from the Google Drive link as detailed in Readme to `local-storage/`.

Clone the BrainBERT repository and prepare dependencies for building a container image on the desired target platform

```bash
git clone git@github.com:lukasgd/BrainBERT.git && cd BrainBERT
env/podman_build.sh --prepare-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod)
```

In the same directory, also build a container locally for monitoring

```bash
env/podman_build.sh --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod .
```

and, change back to the root directory with

```bash
cd ../..
```

## Transfer data to remote storage

Copy both pretraining dataset and weights to remote storage via

```bash
cp -r local-storage/{braintreeban.dev,pretrained_weights.zip} remote-storage/
```

Move the code and container dependencies to remote storage

```bash
cp -r local-storage/BrainBERT remote-storage/
```

This step may be sped up by using `scp` directly, i.e.

```bash
tar -cvf -C local-storage brainbert.tar BrainBERT
scp local-storage/brainbert.tar clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert
ssh clariden:/iopsstor/scratch/cscs/${USER}/test-brainbert tar -xvf brainbert.tar
```

## Finish the container build on the remote

Build a container on Clariden

```bash
cd /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT
sbatch slurm/submit-build-image-offline.sh
```

This can be achieved through [PyFirecREST](https://pyfirecrest.readthedocs.io/). This is a client package for [FirecREST](https://eth-cscs.github.io/firecrest-v2/openapi), which is a REST API to interface with Alps. Follow the instructions at https://docs.cscs.ch/access/firecrest/ and create an application `brainbert` on the [Developer Portal](https://docs.cscs.ch/services/devportal/) [https://developer.cscs.ch]() that is subscribed to the `FirecREST-ML - v2` API to use it in the following. After some initialization, the client is ready to submit jobs and launch data transfers on the cluster.

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
    "clariden",
    working_directory=f"/iopsstor/scratch/cscs/{os.environ["USER"]}/test-brainbert/BrainBERT",
    script_local_path="slurm/submit-build-image-offline.sh")
print(build_job)
```

This can be run inside a local container with PyFirecREST installed, e.g. via

```bash
docker run -it --rm -v $(pwd):$(pwd) -w $(pwd) ngc-brainbert:25.06
```

Alternatively to the Python script, you can directly use the CLI using the configuration

```bash
export FIRECREST_CLIENT_ID="..."
export FIRECREST_CLIENT_SECRET="..."
export AUTH_TOKEN_URL="https://auth.cscs.ch/auth/realms/firecrest-clients/protocol/openid-connect/token"
export FIRECREST_URL="https://api.cscs.ch/ml/firecrest/v2
```

and then submit a job with the same parameters (drop `remote://` to upload a local copy of the submission script instead)

```bash
firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-build-image-offline.sh
```

## Reproduce BrainBERT pretraining steps

### Data preparation

Preprocess and extract the pre-training data as detailed in [Readme](https://github.com/lukasgd/BrainBERT?tab=readme-ov-file#brainbert-pre-training-data) using

```bash
PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
    sbatch slurm/submit-extract-raw.sh
PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/braintreebank.dev \
PRETRAIN_DATA_RAW_DIR=/iopsstor/scratch/cscs/${USER}/test-brainbert/pretrain_data \
    sbatch slurm/submit-preprocess-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
preprocess_job = client.submit(
    "clariden",
    working_directory=f"/iopsstor/scratch/cscs/{os.environ["USER"]}/test-brainbert/BrainBERT",
    script_local_path="slurm/submit-preprocess-prod.sh")
print(preprocess_job)
```

or

```bash
firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-preprocess-prod.sh
```



### Submit pretraining job and monitor progress

Submit a training job via

```bash
sbatch slurm/submit-train-prod.sh
```

or analogously through PyFirecREST (omitting the initialization)

```python
train_job = client.submit(
    "clariden",
    working_directory=f"/iopsstor/scratch/cscs/{os.environ["USER"]}/test-brainbert/BrainBERT",
    script_local_path="slurm/submit-train-prod.sh")
print(train_job)
```

or 

```bash
firecrest submit \
    --system clariden \
    --working-dir /iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT \
    --account a-csstaff \
    remote:///iopsstor/scratch/cscs/${USER}/test-brainbert/BrainBERT/slurm/submit-train-prod.sh
```

Monitor training progress by running a local MLflow instance

```bash
docker run --rm -v $(pwd):$(pwd) -w $(pwd)/remote-storage/BrainBERT/outputs ngc-brainbert:25.06 mlflow ui
```

### Fetch results upon completion

Upon completion, the saved checkpoints can be accessed in the `outputs` directory and synchronized back to local storage,

```bash
cp -r remote-storage/BrainBERT/outputs/<run-dir> local-storage
```

and the remote storage unmounted

```bash
umount remote-storage
```
