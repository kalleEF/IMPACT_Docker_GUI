#!/bin/bash
# =============================================================================
# docker_build_push.sh: build one of the two images by hand, and push it if wanted
# =============================================================================
#
# PURPOSE
#   Builds an image from one of the Dockerfiles in docker_setup and, with --push,
#   uploads it to Docker Hub (the public image registry of Docker). The IMPACT Docker
#   GUI builds the model image by itself; this script is for the maintainer, mainly for
#   the prerequisite image (see docker_setup/README.md).
#
# WHEN IT RUNS
#   Only when a person starts it, from the docker_setup folder (the build context below
#   is taken relative to the current folder):
#       cd docker_setup
#       bash bash/docker_build_push.sh [--image-name <name>] [--image-tag <tag>] <dockerfile> [--push]
#   Examples:
#       bash bash/docker_build_push.sh Dockerfile.prerequisite.IMPACTncdGER
#       bash bash/docker_build_push.sh --image-name prerequisite.impactncdger --image-tag latest Dockerfile.prerequisite.IMPACTncdGER --push
#
# WHAT IT CHANGES
#   - Builds the image <image-name>:<image-tag> on this computer, always from scratch
#     ("--no-cache"). Without --image-name the name is the Dockerfile name without the
#     word "Dockerfile.", in small letters. The tag is "local" unless --image-tag is given.
#   - Build context ("the files Docker may copy into the image"): the repository folder
#     ("..") for Dockerfile.IMPACTncdGER, the docker_setup folder (".") for any other
#     Dockerfile.
#   - With --push only: signs in to Docker Hub and uploads the image as
#     <DOCKERHUB_USERNAME>/<image-name>:<image-tag>. DOCKERHUB_USERNAME and
#     DOCKERHUB_TOKEN come from the environment or from the file .env in the current
#     folder, for example:
#         export DOCKERHUB_USERNAME=yourusername
#         export DOCKERHUB_TOKEN=youraccesstoken
#     Without a token the script asks for the Docker Hub sign-in.
#
# WHAT IT NEVER TOUCHES
#   Files of the repository, containers, and other images. Without --push nothing leaves
#   this computer.
# =============================================================================

set -euo pipefail

# Parse arguments for image name, tag, and dockerfile
IMAGE_TAG="local"
PUSH_IMAGE=false
DOCKERFILE=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --image-name)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --push)
      PUSH_IMAGE=true
      shift
      ;;
    *)
      DOCKERFILE="$1"
      shift
      ;;
  esac
done

# Ensure DOCKERFILE is set before IMAGE_NAME is derived
if [[ -z "$DOCKERFILE" ]]; then
  echo "Error: Dockerfile argument is required."
  exit 1
fi

# --- Docker Permission Check ---
# Check if the user can connect to the Docker daemon
if ! docker info > /dev/null 2>&1; then
  echo "---------------------------------------------------------------------"
  echo "Error: Cannot connect to the Docker daemon."
  echo "Please ensure Docker is running and you have the necessary permissions."
  echo "You might need to:"
  echo "  1. Start the Docker daemon."
  echo "  2. Add your user to the 'docker' group:"
  echo "     sudo usermod -aG docker $USER"
  echo "     (You'll need to log out and back in for this change to take effect)"
  echo "  3. Or run this script using 'sudo':"
  echo "     sudo $0 [options] <dockerfile>"
  echo "---------------------------------------------------------------------"
  exit 1
fi
# --- End Docker Permission Check ---

# Remove hardcoded default for IMAGE_NAME
# Respect user-defined name if provided, otherwise derive from Dockerfile
if [[ -z "${IMAGE_NAME:-}" ]]; then
  IMAGE_NAME="$(basename "$DOCKERFILE" | sed 's/^[Dd]ockerfile\.//' | tr '[:upper:]' '[:lower:]')"
fi

# Convert image name and tag to lowercase
if [[ "$IMAGE_NAME" != "${IMAGE_NAME,,}" ]]; then
    echo "Image name '$IMAGE_NAME' converted to lowercase."
    IMAGE_NAME="${IMAGE_NAME,,}"
fi
if [[ "$IMAGE_TAG" != "${IMAGE_TAG,,}" ]]; then
    echo "Image tag '$IMAGE_TAG' converted to lowercase."
    IMAGE_TAG="${IMAGE_TAG,,}"
fi

# Construct the image name for building
BUILD_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# Function for timestamped log messages
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Skip credential checks if push argument is false
if [ "$PUSH_IMAGE" = true ]; then
  # Source .env file if it exists (only when pushing)
  if [[ -f ".env" ]]; then
    echo "Sourcing environment variables from .env"
    source .env
  fi

  if [[ -z "${DOCKERHUB_USERNAME:-}" ]]; then
    read -p "Enter your Docker Hub username: " DOCKERHUB_USERNAME
  fi

  # Construct the full image name for pushing
  FULL_IMAGE_NAME="${DOCKERHUB_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"

  log "Logging into Docker Hub..."
  if [[ -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" ]]; then
    log "Environment variables DOCKERHUB_USERNAME and/or DOCKERHUB_TOKEN not set."
    log "Please log in manually:"
    docker login
  else
    if echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin; then
      log "Docker login successful."
    else
      log "Docker login failed."
      exit 1
    fi
  fi
fi

# Build the Docker image
log "Building Docker image..."
# Use parent directory as build context for Dockerfile.IMPACTncdGER to include entire project
# Use current directory for other dockerfiles
if [[ "$(basename "$DOCKERFILE")" == "Dockerfile.IMPACTncdGER" ]]; then
  BUILD_CONTEXT=".."
  log "Using parent directory (..) as build context for Dockerfile.IMPACTncdGER"
else
  BUILD_CONTEXT="."
  log "Using current directory (.) as build context for $(basename "$DOCKERFILE")"
fi

if docker build --no-cache -f "$DOCKERFILE" -t "$BUILD_IMAGE_NAME" "$BUILD_CONTEXT"; then
  log "Docker image built successfully."
else
  log "Docker image build failed."
  exit 1
fi

# Push the Docker image to Docker Hub
if [ "$PUSH_IMAGE" = true ]; then
  log "Tagging Docker image for Docker Hub..."
  docker tag "$BUILD_IMAGE_NAME" "$FULL_IMAGE_NAME"

  log "Pushing Docker image to Docker Hub..."
  if docker push "$FULL_IMAGE_NAME"; then
    log "Docker image pushed successfully."
  else
    log "Docker push failed."
    exit 1
  fi
else
  log "Skipping Docker push as --push argument not provided."
fi

# Display the final Docker image name
echo "Final Docker image name: ${IMAGE_NAME}:${IMAGE_TAG}"