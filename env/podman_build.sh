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
    echo "  --base-image <img>   Specify the base image (required for offline builds)"
    echo "  --platform <arch>    Set the target platform for the build (e.g., linux/arm64)"
    echo "  --help               Display this help message and exit"
    echo ""
    echo "Examples (online build):"
    echo "  $0 ngc-pytorch:25.06 -f env/Dockerfile.dev --build-arg BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3 ."
    echo "  $0 --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod ."
    echo ""
    echo "Example (offline build):"
    echo "  $0 --prepare-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod"
    echo "  $0 --build-offline --base-image nvcr.io/nvidia/pytorch:25.06-py3 ngc-brainbert:25.06 -f env/Dockerfile.prod-offline ."
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
        --base-image)
            BASE_IMAGE="$2"
            shift 2
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
elif [ ${BUILD_OFFLINE:-0} -eq 1 ] && [ -z "$BASE_IMAGE" ]; then
    echo "Error: --base-image is required when --build-offline is specified." >&2
    exit 1
elif [ ${PREPARE_OFFLINE:-0} -eq 1 ] && [ -z "$BASE_IMAGE" ]; then
    echo "Error: --base-image is required when --prepare-offline is specified." >&2
    exit 1
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

if command -v enroot >/dev/null 2>&1; then
    SQSH_FILE=${CE_IMAGES:-/capstor/scratch/cscs/${USER}/ce-images}/${IMAGE//:/+}.sqsh

    if [ -f "$SQSH_FILE" ]; then
        echo "Error: Squash image already exists: $SQSH_FILE"
        exit 1
    fi
fi

if [ ${PREPARE_OFFLINE:-0} -eq 1 ] || [ ${BUILD_OFFLINE:-0} -eq 1 ]; then

    : "${BUILD_DEPS:=build_deps}"

    if [ -z "$BASE_IMAGE" ]; then
        echo "Error: Could not find --base-image argument (required for offline builds)." >&2
        exit 1
    fi

    BASE_IMAGE_TAR="$(echo "${BASE_IMAGE}${PLATFORM_ARCH:+-${PLATFORM_ARCH}}" | sed 's|/|-|g; s|:|+|g').tar"

fi


if [ ${PREPARE_OFFLINE:-0} -eq 1 ]; then

    if [ -d "${BUILD_DEPS}" ]; then
        echo "Error: BUILD_DEPS directory exists already: ${BUILD_DEPS}" >&2
        exit 1
    fi
    echo "Using build deps for offline mode at: ${BUILD_DEPS}"

    DOCKERFILE="$(printf "%s\n" "$@" | grep -A 1 -- '-f' | tail -n 1 || echo "env/Dockerfile.prod")"
    APT_DEPS=($(grep '^ENV APT_DEPS=' "${DOCKERFILE}" | awk -F'"' '{print $2}'))

    if [ ${#APT_DEPS[@]} -eq 0 ]; then
        echo "Error: Could not find APT_DEPS in Dockerfile: ${DOCKERFILE}" >&2
        exit 1
    else
        echo "Found APT_DEPS: ${APT_DEPS[*]}"
    fi

    NCCL_TESTS_VERSION=$(grep '^ENV NCCL_TESTS_VERSION=' "${DOCKERFILE}" | awk -F'=' '{print $2}')
    if [ -z "${NCCL_TESTS_VERSION}" ]; then
        echo "Error: Could not find NCCL_TESTS_VERSION in Dockerfile: ${DOCKERFILE}" >&2
        exit 1
    else
        echo "Found NCCL_TESTS_VERSION: ${NCCL_TESTS_VERSION}"
    fi

    set -x
    mkdir -p ${BUILD_DEPS}/{images,apt,python,src}

    ${CONTAINER_RUNTIME} pull ${PLATFORM_ARCH:+--platform ${PLATFORM_ARCH}} ${BASE_IMAGE}

    if [[ "${CONTAINER_RUNTIME}" = "podman" ]]; then
        ${CONTAINER_RUNTIME} save -o ${BUILD_DEPS}/images/"${BASE_IMAGE_TAR}" ${BASE_IMAGE}
    else
        ${CONTAINER_RUNTIME} save ${PLATFORM_ARCH:+--platform ${PLATFORM_ARCH}} -o ${BUILD_DEPS}/images/"${BASE_IMAGE_TAR}" ${BASE_IMAGE}
    fi

    ${CONTAINER_RUNTIME} run --rm -v "$(pwd):$(pwd)" -w "$(pwd)" ${BASE_IMAGE} bash -c "\
    cd ${BUILD_DEPS}/apt

    apt-get update && \
    apt-get install -y --download-only --no-install-recommends \"\$@\" && \
    mv /var/cache/apt/archives/*.deb ./
    " _ "${APT_DEPS[@]}"

    wget -O ${BUILD_DEPS}/src/nccl-tests-${NCCL_TESTS_VERSION}.tar.gz \
      https://github.com/NVIDIA/nccl-tests/archive/refs/tags/v${NCCL_TESTS_VERSION}.tar.gz

    ${CONTAINER_RUNTIME} run --rm -v "$(pwd):$(pwd)" -w "$(pwd)" ${BASE_IMAGE} bash -c "\
    cd ${BUILD_DEPS}/python

    pip download --dest . -v --no-build-isolation --no-cache --no-dependencies \
        pytorch-ranger torch-optimizer  # specific to BrainBERT

    grep -v 'torch_optimizer'  ../../requirements.txt | \
        pip download --dest . -v --no-build-isolation --no-cache -r /dev/stdin
    "
    set +x

else

    if [ ${BUILD_OFFLINE:-0} -eq 1 ]; then
 
        if [ ! -d "${BUILD_DEPS}" ]; then
            echo "Error: BUILD_DEPS directory does not exist: ${BUILD_DEPS}" >&2
            exit 1
        fi
        echo "Using build deps for offline mode at: ${BUILD_DEPS}"

        set -x
        ${CONTAINER_RUNTIME} load -i ${BUILD_DEPS}/images/"${BASE_IMAGE_TAR}" \
            || { STATUS=$?; echo "Error: ${CONTAINER_RUNTIME} load failed (exit code: $STATUS)"; exit $STATUS; }
        set +x
    fi

    set -x 
    ${CONTAINER_RUNTIME} build ${BUILD_OFFLINE:+--network=none} ${PLATFORM_ARCH:+--platform ${PLATFORM_ARCH}} -t $USER/$IMAGE ${BASE_IMAGE:+--build-arg BASE_IMAGE=${BASE_IMAGE}} "${@:2}" \
        || { STATUS=$?; set +x; echo "Error: ${CONTAINER_RUNTIME} build failed (exit code: $STATUS)"; exit $STATUS; }
    set +x

    if command -v enroot >/dev/null 2>&1; then
        set -x
        enroot import -x mount -o ${SQSH_FILE} ${CONTAINER_RUNTIME}://$USER/$IMAGE \
            || { STATUS=$?; set +x; if [ ! -f "${SQSH_FILE}" ]; then echo "Error: enroot import failed (exit code: $STATUS)"; exit $STATUS; else exit 0; fi }
        set +x
    fi
fi