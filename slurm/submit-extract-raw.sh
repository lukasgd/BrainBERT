#!/bin/bash -l

#SBATCH --job-name brainbert-extract-raw
#SBATCH --time 2:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

export PRETRAIN_DATA_RAW_DIR=${PRETRAIN_DATA_RAW_DIR:-/capstor/store/path/to/braintreebank.dev/}

srun -ul bash -c "
    pwd

    if [ ! -d ${PRETRAIN_DATA_RAW_DIR} ]; then
        PRETRAIN_DATA_TAR_FILE=${PRETRAIN_DATA_RAW_DIR%/}.tar
        tar -xvf \${PRETRAIN_DATA_TAR_FILE} -C \$(dirname \${PRETRAIN_DATA_TAR_FILE})
    fi

    cd ${PRETRAIN_DATA_RAW_DIR}
    find  . -maxdepth 1 -name '*.zip' -print0 | xargs -0 -P 8 -I {} unzip {}
    mkdir all_subject_data && cd all_subject_data
    find  ../subject_data/ -name '*.h5.zip' -print0 | xargs -0 -P 8 -I {} unzip {}

"