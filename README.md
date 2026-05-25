# Hello World Agent

A minimal HTTP service for testing the same Docker image on three serverless container platforms:

| Cloud | Platform | Deploy script |
|-------|----------|---------------|
| AWS | App Runner | [`deploy/aws/deploy-apprunner.sh`](deploy/aws/deploy-apprunner.sh) |
| GCP | Cloud Run | [`deploy/gcp/deploy-cloudrun.sh`](deploy/gcp/deploy-cloudrun.sh) |
| Azure | Container Apps | [`deploy/azure/deploy-containerapps.sh`](deploy/azure/deploy-containerapps.sh) |

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | `{"status":"ok"}` — platform health checks |
| GET | `/` | `Hello, World!` |
| GET | `/agent` | Service metadata (name, version, `cloud_provider`) |
| GET | `/docs` | OpenAPI UI (FastAPI) |

Environment variables (set by deploy scripts or locally):

- `PORT` — listen port (default `8080`)
- `SERVICE_NAME` — default `hello-world-agent`
- `VERSION` — default `0.1.0`
- `CLOUD_PROVIDER` — `aws`, `gcp`, `azure`, or `local`

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [curl](https://curl.se/) and optionally [jq](https://jqlang.github.io/jq/)

Per cloud (install and authenticate before deploying):

| Cloud | CLI | Auth |
|-------|-----|------|
| AWS | [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | `aws configure` or SSO |
| GCP | [gcloud](https://cloud.google.com/sdk/docs/install) | `gcloud auth login` and `gcloud config set project PROJECT_ID` |
| Azure | [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | `az login` |

Billing must be enabled on each account. Pick a region close to you and set the env vars below if you do not want the defaults.

## Local development

```bash
cd hello-world-agent

# Run without Docker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export CLOUD_PROVIDER=local
uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload
```

```bash
# Run with Docker
docker build -t hello-world-agent:0.1.0 .
docker run --rm -p 8080:8080 -e CLOUD_PROVIDER=local hello-world-agent:0.1.0
```

Verify:

```bash
curl -s http://localhost:8080/health
curl -s http://localhost:8080/
curl -s http://localhost:8080/agent | jq .
```

## Deploy

From the project root (`hello-world-agent/`):

### AWS App Runner

```bash
export AWS_REGION=us-east-1   # optional, default us-east-1
./deploy/aws/deploy-apprunner.sh
```

The script will:

1. Create an ECR repository (if missing)
2. Build and push the image
3. Create `AppRunnerECRAccessRole` for ECR pull (one-time, unless `APPRUNNER_ACCESS_ROLE_ARN` is set)
4. Create or update the App Runner service with health check `GET /health`
5. Smoke-test `/health`, `/`, and `/agent`

**Cost note:** App Runner keeps at least one instance warm; expect ongoing cost while the service exists.

### GCP Cloud Run

```bash
export GCP_PROJECT_ID=your-project-id   # or: gcloud config set project ...
export GCP_REGION=us-central1           # optional
./deploy/gcp/deploy-cloudrun.sh
```

Uses Cloud Build to push to Artifact Registry, then deploys a public Cloud Run service on port 8080. Cloud Run scales to zero when idle.

### Azure Container Apps

```bash
export AZURE_RESOURCE_GROUP=hello-world-agent-rg   # optional
export AZURE_LOCATION=eastus                       # optional
export AZURE_ACR_NAME=youruniqueacrname            # optional; auto-generated if unset
./deploy/azure/deploy-containerapps.sh
```

Creates resource group, ACR, Container Apps environment, and the app with external HTTPS ingress. Container Apps can scale to zero on consumption plans.

## Verify (any cloud)

After deploy, the script prints the service URL. You can re-check manually:

```bash
export URL=https://your-service-url
curl -s "$URL/health"
curl -s "$URL/"
curl -s "$URL/agent" | jq .
```

Confirm `cloud_provider` in `/agent` matches the cloud you deployed to.

## Teardown

Remove resources when you are done testing to avoid charges.

### AWS

```bash
SERVICE_ARN=$(aws apprunner list-services --region "$AWS_REGION" \
  --query "ServiceSummaryList[?ServiceName=='hello-world-agent'].ServiceArn | [0]" --output text)
aws apprunner delete-service --region "$AWS_REGION" --service-arn "$SERVICE_ARN"
aws ecr delete-repository --region "$AWS_REGION" --repository-name hello-world-agent --force
# Optional: aws iam detach-role-policy ... && aws iam delete-role --role-name AppRunnerECRAccessRole
```

### GCP

```bash
gcloud run services delete hello-world-agent --region "$GCP_REGION" --quiet
gcloud artifacts repositories delete hello-world-agent --location "$GCP_REGION" --quiet
```

### Azure

```bash
az containerapp delete --name hello-world-agent --resource-group "$AZURE_RESOURCE_GROUP" --yes
az containerapp env delete --name hello-world-env --resource-group "$AZURE_RESOURCE_GROUP" --yes
az acr delete --name "$AZURE_ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --yes
az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait
```

## Project layout

```
hello-world-agent/
├── app/main.py
├── requirements.txt
├── Dockerfile
├── deploy/
│   ├── aws/deploy-apprunner.sh
│   ├── gcp/deploy-cloudrun.sh
│   └── azure/deploy-containerapps.sh
└── README.md
```

## Next steps

- Add a GitHub Actions workflow to deploy to all three clouds on push
- Replace this demo with a real agent (e.g. Cursor SDK) and manage secrets via each cloud’s secret store
- Add Terraform modules for reproducible infrastructure
