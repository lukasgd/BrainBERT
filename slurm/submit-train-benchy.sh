#!/bin/bash -l

#SBATCH --job-name brainbert-benchy
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 2
#SBATCH --ntasks-per-node 4
#SBATCH --gpus-per-node 4

set -euxo pipefail

export PRETRAIN_DATA_DIR=${PRETRAIN_DATA_DIR:-$SCRATCH/BrainBERT/pretrain_data/}


PMIX_MCA_psec=native srun -ul --mpi pmix --network disable_rdzv_get --environment ${FCW_CONTAINER_TOML:-./env/ngc-brainbert-25.12-alps2.toml} \
    ${ENABLE_DEBUGGING:+$(which enroot-entrypoint.sh)} \
    bash -c "
    ${ENABLE_DEBUGGING:+sed -i 's/#example/import launch_debugpy/g' run_train.py}
    ${ENABLE_DEBUGGING:+if [ \$SLURM_LOCALID == 0 ]; then cp -r \$SCRATCH/.vscode ./; fi}

    # per-rank dataset replication and -shuffling (to avoid dataset caching in IO measurement)
    ENABLE_BENCHY_TRAIN=1 \
    BENCHY_FULL_DATASET_ON_EACH_RANK=1 \
    BENCHY_CONFIG_FILE=\$PWD/profiling/benchy_train.yaml \
    BENCHY_OUTPUT_FILE=$PWD/outputs/logs/benchy_output-${SLURM_JOB_NAME}-${SLURM_JOBID}.json \
    HYDRA_FULL_ERROR=1 \
    MASTER_ADDR=\$(scontrol show hostnames \$SLURM_JOB_NODELIST | head -n 1) \
    MASTER_PORT=29500 \
    RANK=\${SLURM_PROCID} \
    LOCAL_RANK=\${SLURM_LOCALID} \
    WORLD_SIZE=\${SLURM_NTASKS} \
    python3 ${ENABLE_DEBUGGING:+-Xfrozen_modules=off} run_train.py ${CONF_DIR:+--config-path \$(realpath --relative-to=. ${CONF_DIR})} hydra.run.dir=${HYDRA_BASE_RUN_DIR:-$PWD/outputs}/$(date +'%Y-%m-%d/%H-%M-%S')-${SLURM_JOB_ID} +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.dist_gpu=True ++task.dist_gpu=True ++exp.runner.num_workers=16 +data=masked_spec +model=masked_tf_model_large +data.data=${PRETRAIN_DATA_DIR}/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.total_steps=500000 ++exp.runner.log_step=100000 ++exp.runner.checkpoint_step=100000 ++exp.runner.scheduler.name=reduce_on_plateau
"

