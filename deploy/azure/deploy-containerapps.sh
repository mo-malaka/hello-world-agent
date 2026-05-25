#!/usr/bin/env bash
set -euo pipefail

# Deploy hello-world-agent to Azure Container Apps via ACR.
#
# Required: az CLI, authenticated Azure subscription.
# Optional env:
#   AZURE_RESOURCE_GROUP  (default: hello-world-agent-rg)
#   AZURE_LOCATION        (default: eastus)
#   AZURE_ACR_NAME        (required if not set: derived from subscription, must be globally unique)
#   CONTAINERAPPS_ENV     (default: hello-world-env)
#   SERVICE_NAME          (default: hello-world-agent)
#   IMAGE_TAG             (default: 0.1.0)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-hello-world-agent-rg}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
CONTAINERAPPS_ENV="${CONTAINERAPPS_ENV:-hello-world-env}"
SERVICE_NAME="${SERVICE_NAME:-hello-world-agent}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

log() { echo "==> $*"; }

default_acr_name() {
  local sub
  sub="$(az account show --query id -o tsv | tr -d '-' | cut -c1-12)"
  echo "hwagent${sub}"
}

ensure_acr_name() {
  if [[ -z "${AZURE_ACR_NAME:-}" ]]; then
    AZURE_ACR_NAME="$(default_acr_name)"
    log "Using ACR name: ${AZURE_ACR_NAME} (override with AZURE_ACR_NAME)"
  fi
  # ACR names: alphanumeric only, 5-50 chars
  AZURE_ACR_NAME="$(echo "${AZURE_ACR_NAME}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
  if [[ ${#AZURE_ACR_NAME} -lt 5 ]]; then
    echo "ERROR: AZURE_ACR_NAME must be at least 5 alphanumeric characters" >&2
    exit 1
  fi
}

ensure_resource_group() {
  if ! az group show --name "${AZURE_RESOURCE_GROUP}" &>/dev/null; then
    log "Creating resource group ${AZURE_RESOURCE_GROUP}"
    az group create --name "${AZURE_RESOURCE_GROUP}" --location "${AZURE_LOCATION}" >/dev/null
  fi
}

ensure_acr() {
  if ! az acr show --name "${AZURE_ACR_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" &>/dev/null; then
    log "Creating ACR ${AZURE_ACR_NAME}"
    az acr create \
      --name "${AZURE_ACR_NAME}" \
      --resource-group "${AZURE_RESOURCE_GROUP}" \
      --sku Basic \
      --location "${AZURE_LOCATION}" \
      --admin-enabled true \
      >/dev/null
  fi
}

build_and_push() {
  local image="${AZURE_ACR_NAME}.azurecr.io/${SERVICE_NAME}:${IMAGE_TAG}"
  log "Building and pushing ${image} with ACR build"
  az acr build \
    --registry "${AZURE_ACR_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --image "${SERVICE_NAME}:${IMAGE_TAG}" \
    "${ROOT_DIR}" \
    >/dev/null
  echo "${image}"
}

ensure_containerapps_extension() {
  if ! az extension show --name containerapp &>/dev/null; then
    log "Installing Azure Container Apps CLI extension"
    az extension add --name containerapp --upgrade -y
  fi
}

ensure_containerapps_env() {
  az containerapp env show \
    --name "${CONTAINERAPPS_ENV}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" &>/dev/null && return

  log "Creating Container Apps environment ${CONTAINERAPPS_ENV}"
  az containerapp env create \
    --name "${CONTAINERAPPS_ENV}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --location "${AZURE_LOCATION}" \
    >/dev/null
}

deploy_container_app() {
  local image="$1"
  local exists
  exists="$(az containerapp show \
    --name "${SERVICE_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query name -o tsv 2>/dev/null || true)"

  if [[ -n "${exists}" ]]; then
    log "Updating Container App ${SERVICE_NAME}"
    az containerapp update \
      --name "${SERVICE_NAME}" \
      --resource-group "${AZURE_RESOURCE_GROUP}" \
      --image "${image}" \
      --set-env-vars "CLOUD_PROVIDER=azure" "SERVICE_NAME=${SERVICE_NAME}" "VERSION=${IMAGE_TAG}" \
      >/dev/null
  else
    log "Creating Container App ${SERVICE_NAME}"
    az containerapp create \
      --name "${SERVICE_NAME}" \
      --resource-group "${AZURE_RESOURCE_GROUP}" \
      --environment "${CONTAINERAPPS_ENV}" \
      --image "${image}" \
      --target-port 8080 \
      --ingress external \
      --registry-server "${AZURE_ACR_NAME}.azurecr.io" \
      --registry-username "$(az acr credential show --name "${AZURE_ACR_NAME}" --query username -o tsv)" \
      --registry-password "$(az acr credential show --name "${AZURE_ACR_NAME}" --query passwords[0].value -o tsv)" \
      --env-vars "CLOUD_PROVIDER=azure" "SERVICE_NAME=${SERVICE_NAME}" "VERSION=${IMAGE_TAG}" \
      >/dev/null
  fi

  az containerapp show \
    --name "${SERVICE_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query properties.configuration.ingress.fqdn \
    -o tsv
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
  ensure_acr_name
  ensure_resource_group
  ensure_acr
  IMAGE="$(build_and_push)"
  ensure_containerapps_extension
  ensure_containerapps_env
  FQDN="$(deploy_container_app "${IMAGE}")"
  URL="https://${FQDN}"
  log "Service URL: ${URL}"
  smoke_test "${URL}"
}

main "$@"
