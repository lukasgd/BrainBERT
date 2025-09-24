#example
#python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.multi_gpu=True ++exp.runner.num_workers=16 +data=masked_spec +model=debug_model +data.data=/storage/czw/self_supervised_seeg/all_electrode_data/manifests
from omegaconf import DictConfig, OmegaConf
import hydra
import models
import tasks
from runner import Runner
import logging
import os
import torch
from torch import distributed as dist

import mlflow
from util import mlflow_utils

log = logging.getLogger(__name__)

@hydra.main(config_path="conf")
def main(cfg: DictConfig) -> None:
    log.info("Training")
    log.info(OmegaConf.to_yaml(cfg, resolve=True))
    log.info(f'Working directory {os.getcwd()}')

    if cfg.exp.runner.dist_gpu:
        assert cfg.task.dist_gpu == True

        log.info(f'Initializing torch.distributed on rank {os.environ['RANK']} out of {os.environ['WORLD_SIZE']}')

        dist.init_process_group(backend='nccl')
        log.info(f'Completed torch.distributed initialization: rank {dist.get_rank()}, world size {dist.get_world_size()}')

    experiment_name = cfg.task.name  # alternatively e.g. os.environ('SLURM_JOB_NAME', cfg.task.name)
    mlflow_utils.start_run(experiment_name, cfg)
    mlflow_utils.log_config(cfg)

    task = tasks.setup_task(cfg.task)
    task.load_datasets(cfg.data, cfg.preprocessor)
    model = task.build_model(cfg.model)
    criterion = task.build_criterion(cfg.criterion)
    runner = Runner(cfg.exp.runner, task, model, criterion)
    best_model = runner.train()
    runner.test(best_model)

    mlflow_utils.end_run()

    if cfg.exp.runner.dist_gpu:
        dist.destroy_process_group()

if __name__ == "__main__":
    main()
