#!/usr/bin/env bash
set -euo pipefail

NO_SKIP=false
DOCKER_USER="stefanreinauer"
IMAGE_NAME="amigappc-gcc"
GCC_VERSION="8.4.0"
ADTOOLS_GCC_BRANCH="8"
ADTOOLS_BINUTILS_BRANCH="2.23.2"
SDK_VERSION="54.16"
SDK_URL="${SDK_URL:-}"
CROSS_PREFIX="/opt/amiga-ppc"

usage() {
  cat <<'EOF'
Usage: ./update_docker.sh [options]

Build, tag, and push the ADTools ppc-amigaos-gcc Docker image.

Options:
  -n, --no-skip            Run all steps without prompting
  --docker-user USER       Docker Hub user/organization (default: stefanreinauer)
  --image-name NAME        Docker Hub image name (default: amigappc-gcc)
  --gcc-version VERSION    Tag GCC version (default: 8.4.0)
  --gcc-branch BRANCH      ADTools GCC branch build arg (default: 8)
  --binutils-branch BRANCH ADTools binutils branch build arg (default: 2.23.2)
  --sdk-version VERSION    SDK version build arg (default: 54.16)
  --sdk-url URL            SDK URL build arg
  --cross-prefix DIR       CROSS_PREFIX build arg (default: /opt/amiga-ppc)
  -h, --help               Show this help
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--no-skip)
        NO_SKIP=true
        shift
        ;;
      --docker-user)
        [[ $# -ge 2 ]] || die "--docker-user requires a value"
        DOCKER_USER="$2"
        shift 2
        ;;
      --image-name)
        [[ $# -ge 2 ]] || die "--image-name requires a value"
        IMAGE_NAME="$2"
        shift 2
        ;;
      --gcc-version)
        [[ $# -ge 2 ]] || die "--gcc-version requires a value"
        GCC_VERSION="$2"
        shift 2
        ;;
      --gcc-branch)
        [[ $# -ge 2 ]] || die "--gcc-branch requires a value"
        ADTOOLS_GCC_BRANCH="$2"
        shift 2
        ;;
      --binutils-branch)
        [[ $# -ge 2 ]] || die "--binutils-branch requires a value"
        ADTOOLS_BINUTILS_BRANCH="$2"
        shift 2
        ;;
      --sdk-version)
        [[ $# -ge 2 ]] || die "--sdk-version requires a value"
        SDK_VERSION="$2"
        shift 2
        ;;
      --sdk-url)
        [[ $# -ge 2 ]] || die "--sdk-url requires a value"
        SDK_URL="$2"
        shift 2
        ;;
      --cross-prefix)
        [[ $# -ge 2 ]] || die "--cross-prefix requires a value"
        CROSS_PREFIX="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

ask_and_run() {
  local cmd="$1"
  local response

  if [[ "$NO_SKIP" == true ]]; then
    echo "Next step: -> ${cmd} <-"
    response="N"
  else
    read -r -p "Next step: -> ${cmd} <- Skip? [yN] " response
  fi

  case "$response" in
    [yY])
      echo "Skipping step."
      ;;
    *)
      echo "Executing..."
      if eval "${cmd}"; then
        echo "Step completed successfully."
      else
        echo "Error during execution. Aborting."
        exit 1
      fi
      ;;
  esac

  echo
}

quote_arg() {
  printf '%q' "$1"
}

parse_args "$@"

DATE="$(date +%Y%m%d)"
EXTRA="$(cat .extra 2>/dev/null || true)"

LOCAL_TAG="${IMAGE_NAME}:gcc-v${GCC_VERSION}-${DATE}${EXTRA}"
REMOTE_IMAGE="${DOCKER_USER}/${IMAGE_NAME}"
TAG_GCC_VERSION="${REMOTE_IMAGE}:gcc-v${GCC_VERSION}"
TAG_GCC_VERSION_DATE="${REMOTE_IMAGE}:gcc-v${GCC_VERSION}-${DATE}${EXTRA}"
TAG_LATEST="${REMOTE_IMAGE}:latest"

CMD_BUILD="docker build"
CMD_BUILD+=" --build-arg ADTOOLS_GCC_BRANCH=$(quote_arg "$ADTOOLS_GCC_BRANCH")"
CMD_BUILD+=" --build-arg ADTOOLS_BINUTILS_BRANCH=$(quote_arg "$ADTOOLS_BINUTILS_BRANCH")"
CMD_BUILD+=" --build-arg SDK_VERSION=$(quote_arg "$SDK_VERSION")"
CMD_BUILD+=" --build-arg CROSS_PREFIX=$(quote_arg "$CROSS_PREFIX")"
if [[ -n "$SDK_URL" ]]; then
  CMD_BUILD+=" --build-arg SDK_URL=$(quote_arg "$SDK_URL")"
fi
CMD_BUILD+=" -t $(quote_arg "$LOCAL_TAG") ."

echo "========================================"
echo "Building GCC ${GCC_VERSION} (ADTools branch: ${ADTOOLS_GCC_BRANCH})"
echo "Image: ${REMOTE_IMAGE}"
echo "========================================"
echo

ask_and_run "${CMD_BUILD}"
ask_and_run "docker tag $(quote_arg "$LOCAL_TAG") $(quote_arg "$TAG_GCC_VERSION")"
ask_and_run "docker tag $(quote_arg "$LOCAL_TAG") $(quote_arg "$TAG_GCC_VERSION_DATE")"
ask_and_run "docker push $(quote_arg "$TAG_GCC_VERSION")"
ask_and_run "docker push $(quote_arg "$TAG_GCC_VERSION_DATE")"

echo "========================================"
echo "Tagging GCC ${GCC_VERSION} as 'latest'"
echo "========================================"
echo

ask_and_run "docker tag $(quote_arg "$LOCAL_TAG") $(quote_arg "$TAG_LATEST")"
ask_and_run "docker push $(quote_arg "$TAG_LATEST")"

echo "Script finished."
