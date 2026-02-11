# BrainBERT

BrainBERT is an modeling approach for learning self-supervised representations of intracranial electrode data. See [paper](https://arxiv.org/abs/2302.14367) for details.

We provide the training pipeline below.

The trained weights have been released (see below) and pre-training data can be found at [braintreebank.dev](https://braintreebank.dev)

Instructions to run on Alps (Clariden) at CSCS are specially highlighted as follows.

> [!TIP]
> **Alps**: Download pretraining data to a path under `/capstor/store/` for long-term storage (apply [recommended LUSTRE settings](https://docs.cscs.ch/guides/storage/#lustre-tuning) to the target directory before doing so). Subsequently this is referred to as `/capstor/store/path/to/braintreebank.dev/data/`.

## Installation
Requirements:
- pytorch >= 1.12.1
- [pytorch gradual warmup scheduler](https://github.com/ildoonet/pytorch-gradual-warmup-lr)

```
pip install -r requirements.txt
```

> [!TIP]
> **Alps**: Prepare a container environment as detailed [here](https://docs.cscs.ch/software/ml/pytorch/#running-pytorch-with-the-container-engine-recommended) using the utilities under the `env` directory. A development environment can be built with a container plus virtual environment on top (providing the dependencies from `requirements.txt`). The production environment consists of just a self-contained container image. The commands to build these are given in the help string of [env/podman_build.sh](env/podman_build.sh) and the virtual environment on top of a container is detailed in the [documentation](https://docs.cscs.ch/software/ml/pytorch/#optionally-extend-container-with-virtual-environment) (named `venv-pt-25.06` subsequently and located in the root directory of BrainBERT).

### Input
It is expected that the input is intracranial electrode data that has been Laplacian re-referenced.

## Using BrainBERT embeddings
- pretrained weights are available [here](https://drive.google.com/file/d/14ZBOafR7RJ4A6TsurOXjFVMXiVH6Kd_Q/view?usp=sharing)
- see `notebooks/demo.ipynb` for an example input and example embedding

> [!NOTE]
> **Alps**: Note that this requires adding several `torch.serialization.add_safe_globals` as checkpoint contains code besides weights and `In PyTorch 2.6, we changed the default value of the weights_only argument in torch.load from False to True`.

## Upstream
### BrainBERT pre-training data
The data directory should be structured as:
```
/pretrain_data
  |_manifests
    |_manifests.tsv  <-- each line contains the path to the example and the length
  |_<subject>
    |_<trial>
      |_<example>.npy
```
If using the data from the Brain Treebank, the data can be written using this command:
```
python3 -m data.write_pretrain_data_wavs +data=pretraining_template.yaml \
+data_prep=write_pretrain_split ++data.duration=5 \
++data_prep.pretrain_split=/storage/czw/BrainBERT/data/pretrain_split_trials.json 
++data_prep.out_dir=pretrain_data \
++data.raw_brain_data_dir=/path/to/braintreebank_data/
```
This command expects the Brain Treebank data to have the following structure:
```
/braintreebank_data
  |_electrode_labels
  |_subject_metadata
  |_localization
  |_all_subject_data
    |_sub_*_trial*.h5
```

> [!TIP]
> **Alps**: Steps required to reproduce and avoid millions of files (one for every short-term signal sample as in the default implementation).
> Unzip several feature zip files in /capstor/store/path/to/braintreebank.dev/data/ as required, including
> ```bash
> mkdir all_subject_data && cd all_subject_data
> find  ../subject_data/ -name '*.h5.zip' -print0 | xargs -0 -P 8 -I {} unzip {}
> ```
> Prepare pretraining data in HDF5 (one file per subject) using `++data_prep.out_format=h5` in a dedicated directory `$SCRATCH/BrainBERT/pretrain_data` (apply [recommended LUSTRE settings](https://docs.cscs.ch/guides/storage/#lustre-tuning) on it in advance) using
> 
> ```bash
> python3 -m data.write_pretrain_data_wavs +data=pretraining_template.yaml +data_prep=write_pretrain_split ++data.duration=5 ++data_prep.pretrain_split=/workspace/BrainBERT/data/pretrain_split_trials.json ++data_prep.out_dir=$SCRATCH/BrainBERT/pretrain_data ++data_prep.out_format=h5 ++data.raw_brain_data_dir=/capstor/store/path/to/braintreebank.dev/data/
> ```

### BrainBERT pre-training
```
python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.multi_gpu=True \
  ++exp.runner.num_workers=64 +data=masked_spec +model=masked_tf_model_large \
  +data.data=/path/to/data ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml \
  +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 \
  ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.total_steps=500000
```
Example parameters:
```
/path/to/data = /storage/user123/self_supervised_seeg/pretrain_data/manifests
```

> [!TIP]
> **Alps**: Pre-train on the HDF5 data with `torch.DataParallel` by adding `++data.format=h5`
> ```bash
> python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.multi_gpu=True ++exp.runner.num_workers=64 +data=masked_spec +model=masked_tf_model_large +data.data=$SCRATCH/BrainBERT/pretrain_data/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.total_steps=500000
> ```

> [!TIP]
> **Alps**: For **profiling**, use the Pytorch profiler (`++exp.runner.profile_ranks=all`) to acquire a trace with stack resolution over a few training steps (`++exp.runner.total_steps=10`). To only profile a select few ranks, e.g. the first and second, use `++exp.runner.profile_ranks=[0,1]`. Optionally, a reduced amount of data can be used (`++data.max_samples=1000`). The learning rate schedule needs to be modified to avoid crashes (`++exp.runner.scheduler.name=reduce_on_plateau`).
> ```bash
> python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.multi_gpu=True ++exp.runner.num_workers=64 +data=masked_spec +model=masked_tf_model_large +data.data=$SCRATCH/BrainBERT/pretrain_data/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.profile_ranks=[0,1] ++exp.runner.profiler_schedule='{wait: 5, warmup: 3, active:2}' ++exp.runner.total_steps=10 ++data.max_samples=1000 ++exp.runner.scheduler.name=reduce_on_plateau
> ```
> The resulting trace file `pytorch_trace_s<step_num>_r<rank_num>.json` can be inspected in https://ui.perfetto.dev/.

> [!TIP]
> **Alps**: **Distributed training** on multiple nodes. We use `++exp.runner.dist_gpu=True ++task.dist_gpu=True` instead of `exp.runner.multi_gpu`. `++exp.runner.num_workers=16` is reduced to account for the fact that every process only handles a single GPU. For demonstration purposes, we're again using a short number of steps and increase the logging frequency with `++exp.runner.log_step=10`. To load the required environment, we export PyTorch DDP environment variables and load the Python venv on every rank first.
> 
> ```bash
> srun -ul --time 1:00:00 --nodes 2 --ntasks-per-node 4 --gpus-per-node 4 --environment ./env/ngc-pytorch-25.06.toml bash -c "
>     . venv-pt-25.06/bin/activate
>     MLFLOW_SYSTEM_METRICS_NODE_ID=r\${SLURM_PROCID}-$(hostname) \
>     MASTER_ADDR=\$(scontrol show hostnames \$SLURM_JOB_NODELIST | head -n 1) \
>     MASTER_PORT=29500 \
>     RANK=\${SLURM_PROCID} \
>     LOCAL_RANK=\${SLURM_LOCALID} \
>     WORLD_SIZE=\${SLURM_NTASKS} \
>     python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.dist_gpu=True ++task.dist_gpu=True ++exp.runner.num_workers=16 +data=masked_spec +model=masked_tf_model_large +data.data=$SCRATCH/BrainBERT/pretrain_data/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.log_step=10 ++exp.runner.total_steps=1000 ++exp.runner.scheduler.name=reduce_on_plateau
> "
> ```
> 
> A non-venv version would use `./env/ngc-brainbert-25.06.toml` instead of `./env/ngc-pytorch-25.06.toml` and not require to load the venv at the beginning.
> 
> **Monitoring** of training metrics and system performance can be done via MLflow, which is enabled by setting the following environment variables,
> 
> ```bash
> ENABLE_MLFLOW_MONITORING=1 \
> MLFLOW_TRACKING_URI=$PWD/outputs/mlruns \
> MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING=true \
> MLFLOW_SYSTEM_METRICS_SAMPLING_INTERVAL=1 \
> MLFLOW_SYSTEM_METRICS_SAMPLES_BEFORE_LOGGING=1 \
> srun -ul --time 1:00:00 --nodes 2 --ntasks-per-node 4 --gpus-per-node 4 --environment ./env/ngc-pytorch-25.06.toml bash -c "
>     . venv-pt-25.06/bin/activate
>     MLFLOW_SYSTEM_METRICS_NODE_ID=r\${SLURM_PROCID}-$(hostname) \
>     ... # identical
> "
> ```
> 
> The run can then be monitored in the MLflow UI (in addition to tensorboard that is already integrated) - for this purpose run the `mlflow ui` server in the `outputs` directory (in the container with the loaded Python environment) and forward port 5000 to your local machine. If monitoring with MLflow is not desired, drop all the environment variables containing `MLFLOW` above.
> 
> The SLURM jobs can also be conveniently run asynchronously by submitting them via **sbatch**. The corresponding scripts can be found in the `slurm` directory.

> [!TIP]
> **Alps**: **Data loader benchmarking** - besides the profiling capability, it's possible to quantify the effect of data loading on overall throughput (train/test) with benchy. This is controlled through a configuration file, for which there is an example under the `profiling` dir and enabled purely by setting a few environment variables (use e.g. `ENABLE_BENCHY_TRAIN` to enable it for training). Benchy will print a summary and terminate the program when it has done its measurements.  
> 
> ```bash
> ENABLE_BENCHY_TRAIN=1 \
> BENCHY_CONFIG_FILE=$PWD/profiling/benchy_train.yaml \
> BENCHY_OUTPUT_FILE=benchy_output-${SLURM_JOB_NAME}-${SLURM_JOBID}.json \
> srun -ul --time 1:00:00 --nodes 2 --ntasks-per-node 4 --gpus-per-node 4 --environment ./env/ngc-pytorch-25.06.toml bash -c "
>     . venv-pt-25.06/bin/activate
>     MASTER_ADDR=\$(scontrol show hostnames \$SLURM_JOB_NODELIST | head -n 1) \
>     MASTER_PORT=29500 \
>     RANK=\${SLURM_PROCID} \
>     LOCAL_RANK=\${SLURM_LOCALID} \
>     WORLD_SIZE=\${SLURM_NTASKS} \
>     python3 run_train.py +exp=spec2vec ++exp.runner.device=cuda ++exp.runner.dist_gpu=True ++task.dist_gpu=True ++exp.runner.num_workers=16 +data=masked_spec +model=masked_tf_model_large +data.data=$SCRATCH/BrainBERT/pretrain_data/manifests ++data.format=h5 ++data.val_split=0.01 +task=fixed_mask_pretrain.yaml +criterion=pretrain_masked_criterion +preprocessor=stft ++data.test_split=0.01 ++task.freq_mask_p=0.05 ++task.time_mask_p=0.05 ++exp.runner.total_steps=500000
> "
> ```
