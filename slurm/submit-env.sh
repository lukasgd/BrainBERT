#!/bin/bash -l

#SBATCH --job-name brainbert-env
#SBATCH --time 5:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

srun -u /bin/bash -c "
    env
"