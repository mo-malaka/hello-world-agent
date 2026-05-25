#!/usr/bin/env bash
set -euo pipefail

# Deploy hello-world-agent to GCP Cloud Run via Artifact Registry + Cloud Build.
#
# Required: gcloud CLI, docker (optional if using Cloud Build only), authenticated GCP project.
# Optional env:
#   GCP_PROJECT_ID  (default: gcloud config get-value project)
#   GCP_REGION      (default: us-central1)
#   SERVICE_NAME    (default: hello-world-agent)
#   IMAGE_TAG       (default: 0.1.0)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
GCP_REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-hello-world-agent}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
AR_REPO="${AR_REPO:-hello-world-agent}"

if [[ -z "${GCP_PROJECT_ID}" || "${GCP_PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: Set GCP_PROJECT_ID or run: gcloud config set project YOUR_PROJECT_ID" >&2
  exit 1
fi

IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

log() { echo "==> $*"; }

enable_apis() {
  log "Enabling required APIs"
  gcloud services enable \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    --project="${GCP_PROJECT_ID}"
}

ensure_artifact_registry() {
  if ! gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" &>/dev/null; then
    log "Creating Artifact Registry repository ${AR_REPO}"
    gcloud artifacts repositories create "${AR_REPO}" \
      --repository-format=docker \
      --location="${GCP_REGION}" \
      --project="${GCP_PROJECT_ID}" \
      --description="hello-world-agent images"
  fi
}

build_and_push() {
  log "Building and pushing ${IMAGE} with Cloud Build"
  gcloud builds submit "${ROOT_DIR}" \
    --tag "${IMAGE}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_REGION}"
}

deploy_cloud_run() {
  log "Deploying Cloud Run service ${SERVICE_NAME}"
  gcloud run deploy "${SERVICE_NAME}" \
    --image "${IMAGE}" \
    --platform managed \
    --region "${GCP_REGION}" \
    --project "${GCP_PROJECT_ID}" \
    --port 8080 \
    --allow-unauthenticated \
    --set-env-vars "CLOUD_PROVIDER=gcp,SERVICE_NAME=${SERVICE_NAME},VERSION=${IMAGE_TAG}" \
    --quiet

  gcloud run services describe "${SERVICE_NAME}" \
    --platform managed \
    --region "${GCP_REGION}" \
    --project "${GCP_PROJECT_ID}" \
    --format='value(status.url)'
}

smoke_test() {
  local url="$1"
  log "Smoke testing ${url}"
  curl -fsS "${url}/health"
  echo
  curl -fsS "${url}/"
  echo
  curl -fsS "${url}/agent"
  echo
}

main() {
  enable_apis
  ensure_artifact_registry
  build_and_push
  URL="$(deploy_cloud_run)"
  log "Service URL: ${URL}"
  smoke_test "${URL}"
}

main "$@"
