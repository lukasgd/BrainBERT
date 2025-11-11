#!/bin/bash

set -euo pipefail

function print_help_and_exit() {
    echo "Usage: $0 [OPTION] <image> [podman build options]"
    echo ""
    echo "Build a container image with Podman and convert it to an Enroot squash image."
    echo "If Podman/Enroot are not available, Docker will be used instead."
    echo "The image name should be in the format <name>:<tag>."
    echo "The resulting squash image will be stored under \$CE_IMAGES if defined,"
    echo "else under /capstor/scratch/cscs/\$USER/ce-images/."
    echo ""
    echo "Supported options:"
    echo "  --prepare-offline    Prepare offline build in build_deps/ (requires --base-image)"
    echo "  --build-offline      Build image offline (requires --base-image and prepared build_deps/)"
    echo "  --platform <arch>    Set the target platform for the build (e.g., linux/arm64)"
    echo "  --help               Display this help message and exit"
    echo ""
    echo "Examples (online build, for development and production):"
    echo "  $0 ngc-pytorch:25.06 -f env/Dockerfile.dev --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo "  $0 ngc-brainbert:25.06 -f env/Dockerfile.prod --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo ""
    echo "Example (2-stage build, online download, offline build):"
    echo "  $0 --prepare-offline ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo "  $0 --build-offline ngc-brainbert:25.06 -f env/Dockerfile.prod-multistage --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo ""
    echo "Debugging an intermediate build stage:"
    echo "  podman run -it --rm -e NVIDIA_VISIBLE_DEVICES=void <last-layer-hash> bash"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prepare-offline)
            PREPARE_OFFLINE=1
            echo "Preparing offline build"
            shift
            ;;
        --build-offline)
            BUILD_OFFLINE=1
            echo "Building offline enabled"
            shift
            ;;
        --platform)
            PLATFORM_ARCH="$2"
            shift 2
            ;;
        --help)
            print_help_and_exit
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    print_help_and_exit
elif [ ${PREPARE_OFFLINE:-0} -eq 1 ] && [ ${BUILD_OFFLINE:-0} -eq 1 ]; then
    echo "Error: --prepare-offline and --build-offline cannot be used simultaneously." >&2
    exit 1
fi

IMAGE=$1

if command -v podman >/dev/null 2>&1; then
    echo "Using Podman for building the image."
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    echo "Podman/Enroot not found. Falling back to Docker."
    CONTAINER_RUNTIME="docker"
else
    echo "Error: This script requires 'podman' or 'docker' installed." >&2
    exit 1
fi

if command -v enroot >/dev/null 2>&1 && [ ! ${PREPARE_OFFLINE:-0} -eq 1 ]; then
    SQSH_FILE=${CE_IMAGES:-/capstor/scratch/cscs/${USER}/ce-images}/${IMAGE//:/+}.sqsh

    if [ -f "$SQSH_FILE" ]; then
        echo "Error: Squash image already exists: $SQSH_FILE"
        exit 1
    fi
fi

IMAGE_NAME=localhost/${FIRECREST_USER:-$USER}/$IMAGE  # local image name

if [ ${PREPARE_OFFLINE:-0} -eq 1 ] || [ ${BUILD_OFFLINE:-0} -eq 1 ]; then

    : "${BUILD_DEPS:=build_deps}"

    DOWNLOAD_IMAGE=${IMAGE_NAME}-download

    DOWNLOAD_IMAGE_TAR="$(echo "${DOWNLOAD_IMAGE}${PLATFORM_ARCH:+-${PLATFORM_ARCH}}" | sed 's|/|-|g; s|:|+|g').tar"

    if [ ${PREPARE_OFFLINE:-0} -eq 1 ]; then
        set -x
        mkdir -p ${BUILD_DEPS}/images
        set +x

        if [ -f ${BUILD_DEPS}/images/"${DOWNLOAD_IMAGE_TAR}" ]; then
            echo "Error: Download image tarball already exists: ${BUILD_DEPS}/images/${DOWNLOAD_IMAGE_TAR}" >&2
            exit 1
        fi

        IMAGE_NAME=${DOWNLOAD_IMAGE}
    fi

    if [ ${BUILD_OFFLINE:-0} -eq 1 ]; then
        set -x
        ${CONTAINER_RUNTIME} load -i ${BUILD_DEPS}/images/"${DOWNLOAD_IMAGE_TAR}" \
            || { STATUS=$?; echo "Error: ${CONTAINER_RUNTIME} load failed (exit code: $STATUS)"; exit $STATUS; }
        set +x
    fi

fi

set -x
${CONTAINER_RUNTIME} build ${PREPARE_OFFLINE:+--target download} ${BUILD_OFFLINE:+--network none --build-arg DOWNLOAD_IMAGE=${DOWNLOAD_IMAGE}} ${PLATFORM_ARCH:+--platform ${PLATFORM_ARCH}} -t ${IMAGE_NAME} "${@:2}" \
    || { STATUS=$?; set +x; echo "Error: ${CONTAINER_RUNTIME} build failed (exit code: $STATUS)"; exit $STATUS; }
set +x

if [ ${PREPARE_OFFLINE:-0} -eq 1 ]; then
    if [[ "${CONTAINER_RUNTIME}" = "podman" ]]; then
        set -x
        ${CONTAINER_RUNTIME} save -o ${BUILD_DEPS}/images/"${DOWNLOAD_IMAGE_TAR}" ${IMAGE_NAME}
        set +x
    else
        set -x
        ${CONTAINER_RUNTIME} save ${PLATFORM_ARCH:+--platform ${PLATFORM_ARCH}} -o ${BUILD_DEPS}/images/"${DOWNLOAD_IMAGE_TAR}" ${IMAGE_NAME}
        set +x
    fi
elif command -v enroot > /dev/null 2>&1; then
    set -x
    enroot import -x mount -o ${SQSH_FILE} ${CONTAINER_RUNTIME}://${IMAGE_NAME} \
        || { STATUS=$?; set +x; if [ ! -f "${SQSH_FILE}" ]; then echo "Error: enroot import failed (exit code: $STATUS)"; exit $STATUS; else exit 0; fi }
    set +x
fi

