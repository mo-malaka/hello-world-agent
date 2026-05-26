#!/usr/bin/env bash
set -euo pipefail

# Deploy hello-world-agent to AWS App Runner via ECR.
#
# Required: aws CLI, docker, authenticated AWS credentials.
# Optional env:
#   AWS_REGION          (default: us-east-1)
#   SERVICE_NAME        (default: hello-world-agent)
#   IMAGE_TAG           (default: 0.1.0)
#   APPRUNNER_ACCESS_ROLE_ARN  (auto-created if unset and role missing)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
SERVICE_NAME="${SERVICE_NAME:-hello-world-agent}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
ECR_REPO="${SERVICE_NAME}"
ACCESS_ROLE_NAME="${ACCESS_ROLE_NAME:-AppRunnerECRAccessRole}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
IMAGE="${ECR_URI}:${IMAGE_TAG}"

log() { echo "==> $*"; }

ensure_ecr_repo() {
  if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" &>/dev/null; then
    log "Creating ECR repository ${ECR_REPO}"
    aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null
  fi
}

build_and_push() {
  log "Building image"
  docker build -t "${SERVICE_NAME}:${IMAGE_TAG}" "${ROOT_DIR}"

  log "Logging in to ECR"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  log "Pushing ${IMAGE}"
  docker tag "${SERVICE_NAME}:${IMAGE_TAG}" "${IMAGE}"
  docker push "${IMAGE}"
}

ensure_access_role() {
  if [[ -n "${APPRUNNER_ACCESS_ROLE_ARN:-}" ]]; then
    echo "${APPRUNNER_ACCESS_ROLE_ARN}"
    return
  fi

  local role_arn
  if role_arn="$(aws iam get-role --role-name "${ACCESS_ROLE_NAME}" --query Role.Arn --output text 2>/dev/null)"; then
    echo "${role_arn}"
    return
  fi

  log "Creating IAM role ${ACCESS_ROLE_NAME} for App Runner ECR access (one-time)"
  aws iam create-role \
    --role-name "${ACCESS_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "build.apprunner.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null

  aws iam attach-role-policy \
    --role-name "${ACCESS_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess

  aws iam get-role --role-name "${ACCESS_ROLE_NAME}" --query Role.Arn --output text
}

source_config() {
  local access_role_arn="$1"
  local anthropic_env_json=""
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    anthropic_env_json="${anthropic_env_json}, \"ANTHROPIC_API_KEY\": \"${ANTHROPIC_API_KEY//\"/\\\"}\""
  fi
  if [[ -n "${ANTHROPIC_MODEL:-}" ]]; then
    anthropic_env_json="${anthropic_env_json}, \"ANTHROPIC_MODEL\": \"${ANTHROPIC_MODEL//\"/\\\"}\""
  fi
  cat <<EOF
{
  "AuthenticationConfiguration": {
    "AccessRoleArn": "${access_role_arn}"
  },
  "AutoDeploymentsEnabled": false,
  "ImageRepository": {
    "ImageIdentifier": "${IMAGE}",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "8080",
      "RuntimeEnvironmentVariables": {
        "CLOUD_PROVIDER": "aws",
        "SERVICE_NAME": "${SERVICE_NAME}",
        "VERSION": "${IMAGE_TAG}"${anthropic_env_json}
      }
    }
  }
}
EOF
}

health_check_config() {
  cat <<'EOF'
{
  "Protocol": "HTTP",
  "Path": "/health",
  "Interval": 10,
  "Timeout": 5,
  "HealthyThreshold": 1,
  "UnhealthyThreshold": 5
}
EOF
}

deploy_service() {
  local access_role_arn="$1"
  local existing_arn
  existing_arn="$(aws apprunner list-services --region "${AWS_REGION}" \
    --query "ServiceSummaryList[?ServiceName=='${SERVICE_NAME}'].ServiceArn | [0]" \
    --output text 2>/dev/null || echo "None")"

  if [[ "${existing_arn}" != "None" && -n "${existing_arn}" ]]; then
    log "Updating App Runner service ${SERVICE_NAME}"
    aws apprunner update-service \
      --region "${AWS_REGION}" \
      --service-arn "${existing_arn}" \
      --source-configuration "$(source_config "${access_role_arn}")" \
      --health-check-configuration "$(health_check_config)" \
      >/dev/null
    SERVICE_ARN="${existing_arn}"
  else
    log "Creating App Runner service ${SERVICE_NAME}"
    SERVICE_ARN="$(aws apprunner create-service \
      --region "${AWS_REGION}" \
      --service-name "${SERVICE_NAME}" \
      --source-configuration "$(source_config "${access_role_arn}")" \
      --health-check-configuration "$(health_check_config)" \
      --query Service.ServiceArn \
      --output text)"
  fi

  log "Waiting for service to reach RUNNING (this may take a few minutes)"
  aws apprunner wait service-running --region "${AWS_REGION}" --service-arn "${SERVICE_ARN}"

  aws apprunner describe-service \
    --region "${AWS_REGION}" \
    --service-arn "${SERVICE_ARN}" \
    --query Service.ServiceUrl \
    --output text
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

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    log "Smoke testing /agent/invoke"
    curl -fsS -X POST "${url}/agent/invoke" \
      -H "Content-Type: application/json" \
      -d '{"input":"Return your service metadata","max_steps":3}' >/dev/null
    echo
  else
    log "Skipping /agent/invoke (set ANTHROPIC_API_KEY to enable)"
  fi
}

main() {
  ensure_ecr_repo
  build_and_push
  ACCESS_ROLE_ARN="$(ensure_access_role)"
  URL="$(deploy_service "${ACCESS_ROLE_ARN}")"
  URL="https://${URL}"
  log "Service URL: ${URL}"
  smoke_test "${URL}"
}

main "$@"
