#!/bin/bash

#SBATCH --job-name brainbert
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 2
#SBATCH --ntasks-per-node 4
#SBATCH --gpus-per-node 4

set -euxo pipefail

export ENABLE_MLFLOW_MONITORING=1
export MLFLOW_TRACKING_URI=$PWD/outputs/mlruns
export MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING=true
export MLFLOW_SYSTEM_METRICS_SAMPLING_INTERVAL=1
export MLFLOW_SYSTEM_METRICS_SAMPLES_BEFORE_LOGGING=1

export PRETRAIN_DATA_DIR=${PRETRAIN_DATA_DIR:-$SCRATCH/BrainBERT/pretrain_data/}

srun -ul --environment ./env/ngc-pytorch-25.06.toml bash -c "
    . venv-pt-25.06/bin/activate
    MLFLOW_SYSTEM_METRICS_NODE_ID=r\${SLURM_PROCID}-$(hostname) \
    MASTER_ADDR=\$(scontrol show hostnames \$SLURM_JOB_NODELIST | head -n 1) \
    MASTER_PORT=29500 \
    RANK=\${SLURM_PROCID} \
    LOCAL_RANK=\${SLURM_LOCALID} \
    WORLD_SIZE=\${SLURM_NTASKS} \
    python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.dist_gpu=True ++task.dist_gpu=True ++exp.runner.num_workers=16 +data=masked_spec +model=masked_tf_model_large +data.data=${PRETRAIN_DATA_DIR}/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.log_step=10 ++exp.runner.total_steps=1000 ++exp.runner.scheduler.name=reduce_on_plateau
"