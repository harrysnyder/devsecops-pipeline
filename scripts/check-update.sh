#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Prevent concurrent update checks.
exec 8>/home/buddy/.local/state/devsecops-pipeline/update.lock

if ! flock -n 8; then
    echo "Another update check is already running. Skipping."
    exit 0
fi

echo "Update check lock acquired."

# Skip checking while another deployment is running.
exec 7>/home/buddy/.local/state/devsecops-pipeline/deploy.lock

if ! flock -n 7; then
    echo "A deployment is already running. Skipping update check."
    exit 0
fi

# Keep the deployment lock for the entire update operation.
# deploy.sh will recognize that this process already owns it.
export DEPLOY_LOCK_HELD=1

IMAGE="ghcr.io/harrysnyder/devsecops-pipeline:latest"
CONTAINER="devsecops-api-compose"

echo "Checking GHCR for container updates..."

current_image=$(docker inspect \
    --format '{{.Image}}' \
    "$CONTAINER")

docker pull "$IMAGE"

latest_image=$(docker image inspect \
    --format '{{.Id}}' \
    "$IMAGE")

echo "Running image: $current_image"
echo "Latest image:  $latest_image"

if [[ "$current_image" == "$latest_image" ]]; then
    echo "No update available. Deployment skipped."
    exit 0
fi

FAILED_IMAGE_FILE="/home/buddy/.local/state/devsecops-pipeline/failed-image"

if [[ -f "$FAILED_IMAGE_FILE" ]]; then
    failed_image=$(<"$FAILED_IMAGE_FILE")

    if [[ "$latest_image" == "$failed_image" ]]; then
        echo "WARNING: Latest image previously failed deployment: $latest_image"
        echo "Skipping known-bad image until a different image is published."
        exit 0
    fi
fi

echo "New image detected. Starting deployment..."

if DEPLOY_EXPECTED_IMAGE="$latest_image" bash scripts/deploy.sh; then
    echo "Deployment successful."
    rm -f "$FAILED_IMAGE_FILE"
else
    result=$?
    echo "ERROR: Deployment failed with exit code $result." >&2
    echo "$latest_image" > "$FAILED_IMAGE_FILE"
    echo "Failed image recorded: $latest_image" >&2
    exit "$result"
fi
