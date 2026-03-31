#!/bin/bash

#SBATCH --job-name=nccl-tests-allreduce
#SBATCH --time 30:00
#SBATCH --nodes 80
#SBATCH --ntasks-per-node 4
#SBATCH --output=outputs/reframe_logs/%x-%j.out

# NCCL_SOCKET_IFNAME=hsn FI_LOG_LEVEL=Trace FI_LOG_PROV=cxi FI_LOG_SUBSYS=all NCCL_DEBUG=INFO CE_IMAGES=$PWD/ce-images \
PMIX_MCA_psec=native srun -ul --environment ./env/ngc-brainbert-25.12-alps2.toml --mpi pmix --network=disable_rdzv_get --ntasks-per-node=4 all_reduce_perf -b 8 -e 8G -f 2 -g 1 -c 1 -n 20 -w 5