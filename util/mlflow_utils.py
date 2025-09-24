import os
import time
import logging
import socket
from omegaconf import OmegaConf
import mlflow
from torch import distributed as dist


log = logging.getLogger(__name__)

mlflow_enabled = os.environ.get('ENABLE_MLFLOW_MONITORING') == '1'


def start_run(experiment_name, cfg):
    if not mlflow_enabled:
        return

    if cfg.exp.runner.dist_gpu:
        if dist.get_rank() == 0 and \
            mlflow.get_experiment_by_name(experiment_name) is None:

            log.info(f"Experiment '{experiment_name}' not found. Creating it.")
            mlflow.create_experiment(experiment_name)
    
        dist.barrier()


    mlflow.set_experiment(experiment_name)

    run_name = '_'.join(os.getcwd().split('/')[-2:])
    if 'SLURM_JOB_ID' in os.environ:
        run_name += f"_{os.environ['SLURM_JOB_ID']}"

    if cfg.exp.runner.dist_gpu:
        tmp_run_id_file = os.path.join(os.getcwd(), '.mlflow_run_id')

        if dist.get_rank() == 0:
            mlflow.start_run(run_name=run_name)

            with open(tmp_run_id_file, 'w') as f:
                f.write(mlflow.active_run().info.run_id)
                f.flush()
                os.fsync(f.fileno())

            log.info(f"Launched MLflow run with ID {mlflow.active_run().info.run_id} on rank {dist.get_rank()}")

        while not os.path.exists(tmp_run_id_file):
            time.sleep(1)
            log.info(f"Rank {dist.get_rank()} waiting for MLflow run ID file to become available on {socket.gethostname()}...")

        time.sleep(3)

        with open(tmp_run_id_file, 'r') as f:
            run_id = f.read()

        dist.barrier()

        if dist.get_rank() == 0:
            log.info(f"Removing temporary MLflow run_id file on rank {dist.get_rank()}")
            os.remove(tmp_run_id_file)

        elif os.environ.get('SLURM_LOCALID', '0') == '0':
            log.info(f"Resuming MLflow run with ID {run_id} on rank {dist.get_rank()}")
            mlflow.start_run(run_id=run_id)

    else:
        mlflow.start_run(run_name=run_name)


def end_run():
    if not mlflow_enabled:
        return

    mlflow.end_run()

def log_config(cfg):
    if not mlflow_enabled:
        return

    flat_cfg = _flatten_dict(
        OmegaConf.to_container(cfg, resolve=True, throw_on_missing=True))

    if cfg.exp.runner.dist_gpu:
        if not dist.is_initialized():
            raise ValueError("Distributed process group must be initialized before"
                             " logging config to MLflow.")
        if dist.get_rank() != 0:
            return

        world_size = dist.get_world_size()
    else:
        world_size = 1

    extra_cfg = {}
    for k, v in flat_cfg.items():
        if k.endswith("batch_size"):
            extra_cfg[k.replace("batch_size", "global_batch_size")] = v*world_size

    flat_cfg.update(extra_cfg)

    mlflow.log_params(dict(sorted(flat_cfg.items())))


def _flatten_dict(nested_dict, parent_key=''):

    flat_dict = {}

    for k, v in nested_dict.items():
        new_key = parent_key + '.' + k if parent_key else k
        if isinstance(v, dict) and v:
            flat_dict.update(_flatten_dict(v, new_key))
        else:
            flat_dict[new_key] = v

    return flat_dict

def log_metric(key, value, **kwargs):
    if not mlflow_enabled:
        return

    mlflow.log_metric(key, value, **kwargs)