#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Prevent concurrent deployments.
# Reuse the inherited lock descriptor when called by check-update.sh.
if [[ "${DEPLOY_LOCK_HELD:-}" == "1" ]]; then
    if [[ ! -e /proc/self/fd/7 ]] || \
       [[ "$(readlink /proc/self/fd/7)" != "/home/buddy/.local/state/devsecops-pipeline/deploy.lock" ]]; then
        echo "ERROR: Invalid inherited deployment lock." >&2
        exit 1
    fi
    echo "Using inherited deployment lock."
else
    exec 7>/home/buddy/.local/state/devsecops-pipeline/deploy.lock

    if ! flock -n 7; then
        echo "ERROR: Another deployment is already running." >&2
        exit 1
    fi

    echo "Deployment lock acquired."
fi

echo "Verifying current deployment health..."

current_health=$(docker inspect \
    --format '{{.State.Health.Status}}' \
    devsecops-api-compose 2>/dev/null || true)

if [[ "$current_health" != "healthy" ]]; then
    echo "ERROR: Current deployment is not healthy: ${current_health:-unknown}" >&2
    echo "Refusing to overwrite the known-good rollback image." >&2
    exit 1
fi

echo "Current deployment is healthy."

echo "Preserving current image for rollback..."

previous_image=$(docker inspect     --format '{{.Image}}'     devsecops-api-compose)

docker image tag "$previous_image" devsecops-pipeline:rollback

echo "Rollback image preserved: $previous_image"

if [[ -n "${DEPLOY_EXPECTED_IMAGE:-}" ]]; then
    echo "Using image selected by update checker..."
    expected_image="$DEPLOY_EXPECTED_IMAGE"

    if [[ ! "$expected_image" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        echo "ERROR: Invalid expected image ID." >&2
        exit 1
    fi

    if ! docker image inspect "$expected_image" >/dev/null; then
        echo "ERROR: Expected image is not available locally." >&2
        exit 1
    fi
else
    echo "Pulling latest published container image..."

    if ! docker compose pull api; then
        echo "ERROR: Failed to pull the new container image." >&2
        echo "Existing healthy deployment remains unchanged." >&2
        exit 1
    fi

    expected_image=$(docker image inspect \
        --format '{{.Id}}' \
        ghcr.io/harrysnyder/devsecops-pipeline:latest)
fi

echo "Expected deployment image: $expected_image"
docker image tag "$expected_image" devsecops-pipeline:deploy
echo "Deployment image pinned locally."

echo "Deploying updated container..."

deployment_failed=false

if DEPLOY_IMAGE=devsecops-pipeline:deploy \
    docker compose up -d --no-deps --pull never api; then
    echo "Deployment command completed."
else
    echo "ERROR: Docker Compose deployment failed." >&2
    deployment_failed=true
fi

echo "Deployment status:"
docker compose ps api || true

if [[ "$deployment_failed" == "false" ]]; then
    echo "Waiting for application health check..."

for attempt in {1..12}; do
    health=$(docker inspect \
        --format '{{.State.Health.Status}}' \
        devsecops-api-compose 2>/dev/null || true)

    if [[ "$health" == "healthy" ]]; then
        running_image=$(docker inspect \
            --format '{{.Image}}' \
            devsecops-api-compose)

        if [[ "$running_image" == "$expected_image" ]]; then
            echo "Deployment successful: expected image is healthy."
            exit 0
        fi

        echo "ERROR: Healthy container is running the wrong image." >&2
        echo "Expected: $expected_image" >&2
        echo "Running:  $running_image" >&2
        break
    fi

    echo "Health check $attempt/12: ${health:-unknown}"
    sleep 5
done

fi

echo "ERROR: Deployment failed health verification." >&2
docker compose logs --tail=30 api || true

echo "Rolling back to previous image: $previous_image"

if DEPLOY_IMAGE=devsecops-pipeline:rollback \
    docker compose up -d --no-deps --pull never --force-recreate api; then
    echo "Rollback container started. Verifying health..."

    for attempt in {1..12}; do
        health=$(docker inspect \
            --format '{{.State.Health.Status}}' \
            devsecops-api-compose 2>/dev/null || true)

        if [[ "$health" == "healthy" ]]; then
            restored_image=$(docker inspect \
                --format '{{.Image}}' \
                devsecops-api-compose)

            if [[ "$restored_image" == "$previous_image" ]]; then
                echo "Rollback successful: previous image restored and healthy."
                exit 1
            fi

            echo "ERROR: Rollback container is healthy but running the wrong image." >&2
            echo "Expected: $previous_image" >&2
            echo "Running:  $restored_image" >&2
            break
        fi

        echo "Rollback health check $attempt/12: ${health:-unknown}"
        sleep 5
    done

    echo "ERROR: Rollback container failed health verification." >&2
    docker compose logs --tail=30 api || true
else
    echo "ERROR: Rollback container could not be started." >&2
fi

exit 1
