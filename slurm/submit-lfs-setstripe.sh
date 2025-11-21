#!/bin/bash -l

#SBATCH --job-name brainbert-lfs-setstripe
#SBATCH --time 5:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

srun -ul bash -c "
    lfs setstripe -E 4M -c 1 -E 64M -c 4 -E -1 -c -1 -S 4M ${FIRECREST_WORKDIR}
"