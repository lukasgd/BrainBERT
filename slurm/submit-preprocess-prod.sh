#!/bin/bash -l

#SBATCH --job-name brainbert-preprocess
#SBATCH --time 12:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

export PRETRAIN_DATA_RAW_DIR=${PRETRAIN_DATA_RAW_DIR:-/capstor/store/path/to/braintreebank.dev/data/}
export PRETRAIN_DATA_DIR=${PRETRAIN_DATA_DIR:-$SCRATCH/BrainBERT/pretrain_data/}

# make sure that pretrain_split reflects available trials in all_subject_data, otherwise change path to JSON file
srun -ul --environment ${FCW_CONTAINER_TOML:-./env/ngc-brainbert-25.12-alps2.toml} bash -c "
    python3 -m data.write_pretrain_data_wavs ${CONF_DIR:+--config-path \$(realpath --relative-to=. ${CONF_DIR})} hydra.run.dir=${HYDRA_BASE_RUN_DIR:-$PWD/outputs}/$(date +'%Y-%m-%d/%H-%M-%S')-${SLURM_JOB_ID} +data=pretraining_template.yaml +data_prep=write_pretrain_split ++data.duration=5 ++data_prep.pretrain_split=/workspace/BrainBERT/data/pretrain_split_trials.json ++data_prep.out_dir=${PRETRAIN_DATA_DIR} ++data_prep.out_format=h5 ++data.raw_brain_data_dir=${PRETRAIN_DATA_RAW_DIR}
"