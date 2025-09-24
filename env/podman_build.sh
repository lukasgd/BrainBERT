#!/bin/bash

if [[ $# -lt 1 || " $@ " =~ " --help " ]]; then
    echo "Usage: $0 <image> [podman build options]"
    echo ""
    echo "Build a Podman image and convert it to an Enroot squash image."
    echo "The image name should be in the format <name>:<tag>."
    echo "The resulting squash image will be stored under \$CE_IMAGES if defined,"
    echo "else under /capstor/scratch/cscs/\$USER/ce-images/."
    echo ""
    echo "Examples:"
    echo "  $0 ngc-brainbert:25.06 -f env/Dockerfile.prod --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo ""
    echo "  $0 ngc-pytorch:25.06 -f env/Dockerfile.dev --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo ""
    echo "Debugging an intermediate build stage:"
    echo "  podman run -it --rm -e NVIDIA_VISIBLE_DEVICES=void <last-layer-hash> bash"
    exit 1
fi

IMAGE=$1
SQSH_FILE=${CE_IMAGES:-/capstor/scratch/cscs/${USER}/ce-images}/${IMAGE//:/+}.sqsh

if [ -f "$SQSH_FILE" ]; then
    echo "Error: Squash image already exists: $SQSH_FILE"
    exit 1
fi

set -x
podman build -t $USER/$IMAGE "${@:2}" \
    || { STATUS=$?; set +x; echo "Error: podman build failed (exit code: $STATUS)"; exit $STATUS; }
enroot import -x mount -o ${SQSH_FILE} podman://$USER/$IMAGE \
    || { STATUS=$?; set +x; if [ ! -f "${SQSH_FILE}" ]; then echo "Error: enroot import failed (exit code: $STATUS)"; exit $STATUS; else exit 0; fi }
set +x

