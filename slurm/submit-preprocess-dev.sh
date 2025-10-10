#!/bin/bash

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
srun -ul --environment ./env/ngc-pytorch-25.06.toml bash -c "
    . venv-pt-25.06/bin/activate
    python3 -m data.write_pretrain_data_wavs +data=pretraining_template.yaml +data_prep=write_pretrain_split ++data.duration=5 ++data_prep.pretrain_split=$(realpath data/pretrain_split_trials.json) ++data_prep.out_dir=${PRETRAIN_DATA_DIR} ++data_prep.out_format=h5 ++data.raw_brain_data_dir=${PRETRAIN_DATA_RAW_DIR}
"