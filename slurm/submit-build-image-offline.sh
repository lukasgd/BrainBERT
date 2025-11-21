#!/bin/bash -l

#SBATCH --job-name brainbert-build-offline
#SBATCH --time 1:00:00
#SBATCH --output outputs/logs/%x-%j.out
#SBATCH --nodes 1
#SBATCH --ntasks-per-node 1
#SBATCH --cpus-per-task 288
#SBATCH --gpus-per-node 4

set -euxo pipefail

srun -ul bash -c "
    # wait for systemd to disappear
    while pgrep -U $(id -u) systemd ; do sleep 0.2 ; done

    # cleanup from previous runs, and empty storage from memory
    podman system reset -f
    rm -Rf /dev/shm/$USER/*
    rm -Rf /tmp/xdg-run-$(id -u)*

    # Requires running the following before
    # env/podman_build.sh --prepare-offline --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
    export XDG_RUNTIME_DIR=\"\$(mktemp -d -p \"\${TMPDIR:-/tmp}\" xdg-run-\$UID.XXXXXX)\"
    chmod 700 \"\$XDG_RUNTIME_DIR\"
    env/podman_build.sh --build-offline --platform linux/arm64 ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 .
"