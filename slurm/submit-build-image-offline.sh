#!/bin/bash

#SBATCH --job-name brainbert-build-offline
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

srun -ul bash -c "
    # Requires running the following before
    # env/podman_build.sh --prepare-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod
    env/podman_build.sh --build-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod-offline .
"