# BrainBERT Pre-training Workflow with fcw

This document reimplements the workflow described in [README-firecrest-only.md](README-firecrest-only.md) using `fcw` commands. Refer to that document for background on each step and the underlying PyFirecREST/CLI equivalents.

## Prerequisites

- `fcw` installed (`pip install -e ".[dev]"`)
- Environment variables set: `FIRECREST_URL`, `FIRECREST_CLIENT_ID`, `FIRECREST_CLIENT_SECRET`, `AUTH_TOKEN_URL`, `FIRECREST_SYSTEM`, `FIRECREST_ACCOUNT`
- `FIRECREST_SCRATCH` set to the remote scratch path (e.g., `/iopsstor/scratch/cscs/$USER`)
- `FCW_BRAINBERT_RUN_ID` set to isolate this run (e.g., `run-01`); the remote workdir resolves to `${FIRECREST_SCRATCH}/fcw-BrainBERT-${FCW_BRAINBERT_RUN_ID}`
- Container runtime available (podman or docker)
- On x86 hosts targeting arm64 clusters: `apt install qemu-user-static`
- Working directory: `examples/BrainBERT/`

## Step 0: Obtain Data

Download the braintreebank.dev dataset to the local `braintreebank.dev/` directory (for testing, a subset is sufficient):

```bash
mkdir -p braintreebank.dev
cd braintreebank.dev
wget --mirror --no-parent --cut-dirs=1 --accept zip,json,ipynb --reject-regex '\?' https://braintreebank.dev/data/
```

Or with multithreading:

```bash
cd braintreebank.dev
wget2 --mirror --no-parent --cut-dirs=1 --max-threads=$(($(nproc)/2)) --accept zip,json,ipynb --reject-regex '\?' https://braintreebank.dev/data/
```

## Step 1: Validate Configuration

```bash
fcw config validate
fcw config show
```

**Verify:** Config resolves correctly, credentials are valid, remote system is reachable. Output should show "All checks passed!".

## Step 2: Deploy Container

Build, push, and deploy the container in a single command:

```bash
fcw container deploy ngc-brainbert --wait
```

This runs the full pipeline:
1. Builds the `download` stage locally (with `--platform linux/arm64` from config)
2. Exports and uploads the download image to the remote cluster
3. Submits a SLURM job that builds the `build-offline` stage and imports into enroot

Alternatively, as an explicit 3-step procedure run:

```bash
fcw container build --stage download -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=jfrog.svc.cscs.ch/docker-group-csstaff/alps-images/ngc-pytorch:25.12-py3-alps2 -t ngc-brainbert:25.12-alps2-download .
fcw container push ngc-brainbert:25.12-alps2-download
fcw container build-remote ngc-brainbert:25.12-alps2-download -f env/Dockerfile.prod-multistage -t ngc-brainbert:25.12-alps2 --stage build-offline --build-arg DOWNLOAD_IMAGE=ngc-brainbert:25.12-alps2-download --build-arg BASE_IMAGE=jfrog.svc.cscs.ch/docker-group-csstaff/alps-images/ngc-pytorch:25.12
-py3-alps2  --enroot --wait
```

**Verify:** The squashfs image exists on the remote:
```bash
fcw data ls ce-images
```
Should show `ngc-brainbert+25.12-alps2.sqsh`.

## Step 3: Upload Data

Upload the raw braintreebank dataset:

```bash
fcw data upload braintreebank.dev
```

**Verify:**
```bash
fcw data ls braintreebank.dev
```
Should list the uploaded zip files and metadata.

## Step 4: Extract Raw Data

Extract and unzip the dataset on the remote cluster:

```bash
fcw job submit extract-raw --wait
```

**Verify:** Job completes successfully. Check logs:
```bash
fcw job logs <job_id>
```

## Step 5: Preprocess

Run data preprocessing (CWT computation, writing pre-training splits):

```bash
fcw job submit preprocess --wait
```

**Verify:** Job completes. Preprocessed data exists on remote:
```bash
fcw data ls pretrain_data
```

## Step 6: Train

Submit the pre-training job:

```bash
fcw job submit train
```

Resources: 2 nodes, 4 tasks/node, 4 GPUs/node (defaults from fcw.yaml, overridable via SBATCH overrides).

To chain a training job after a preprocessing one, use the sbatch option `--dependency afterok:$JOB_PREP`, where the job ID can be obtained as in

```bash
JOB_PREP=$(fcw job submit preprocess)
```

**Verify:** Job is running:
```bash
fcw job list
```

To change the model architecture, edit `conf/model/masked_tf_model_large.yaml` and upload

```bash
fcw data upload conf
```

For continuous uploading use the `--watch` option.

## Step 7: Sync Results

Continuously download training outputs (checkpoints, logs) to the local `outputs/` directory:

```bash
fcw data download outputs --watch
```

Monitor training progress with MLflow:

```bash
cd outputs && mlflow ui
```

Inspect results at `http://127.0.0.1:5000/`.

**Verify:** Upon completion, `outputs/` contains checkpoint files (`checkpoint_best.pth`, `checkpoint_last.pth`) under the run subdirectory.

## Benchmarks

### Benchy (Data Loading Performance)

Submit a training run with benchy profiling enabled:

```bash
fcw job submit train-benchy
```

For scaling studies, use SBATCH overrides to sweep node counts:

```bash
for n in 1 2 4 8 16 32 64; do
    fcw job submit --nodes $n --time 01:00:00 --dependency singleton -- train-benchy
done
```

Results are printed to stdout (use `grep 'BENCHY::' <logfile>`).

### NCCL Tests

Run NCCL all-reduce performance tests:

```bash
fcw job submit nccl-tests
```

Override node count for scaling:

```bash
fcw job submit --nodes 16 -- nccl-tests
```

## Notes

- **Run isolation**: Set `FCW_BRAINBERT_RUN_ID` to a unique value for each experiment to get a separate remote workdir.
- **Cross-architecture builds**: The `platform: linux/arm64` setting in `fcw.yaml` ensures containers are built for the target cluster architecture. On x86 hosts, this uses QEMU emulation.
- **Standalone scripts**: All SLURM scripts remain runnable without fcw. The `${FCW_CONTAINER_TOML:-./env/ngc-brainbert-25.12-alps2.toml}` pattern falls back to the local TOML path when fcw is not used.
- **SBATCH overrides**: Any SBATCH option can be overridden at submit time (e.g., `--nodes`, `--time`, `--dependency`). These are injected into the script before submission.
- **Environment variables**: Env vars defined in `fcw.yaml` job configs are injected as shell defaults (`export VAR="${VAR:-value}"`), so pre-set environment variables take precedence.
