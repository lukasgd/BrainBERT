#!/bin/bash -l

#SBATCH --job-name brainbert-build
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

srun -ul bash -c "
    env/podman_build.sh --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod .
"