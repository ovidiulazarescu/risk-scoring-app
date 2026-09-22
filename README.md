# risk-scoring-app

A small FastAPI risk-scoring service with a React frontend, deployed to **AWS ECS Fargate + CloudFront**
by Terraform, and shipped by GitHub Actions using keyless OIDC auth. Forked from
[risk-api](https://github.com/ovidiulazarescu/risk-api) (which runs the same API on Cloud Run and
App Runner) to try a container-on-ECS deployment instead.

## Layout

```
backend/               FastAPI service (same scoring logic as risk-api)
frontend/               React + Vite single-page form that calls the API
infra/aws-bootstrap/    Terraform: S3 bucket for Terraform state
infra/aws/              Terraform: ECR, ECS Fargate + ALB, S3 + CloudFront, GitHub OIDC role
.github/workflows/      deploy-aws.yml
```

## Architecture

```
Browser
   |
   v
CloudFront (single HTTPS domain, *.cloudfront.net)
   |-- default behavior -----------> S3 bucket (built frontend, private, via OAC)
   `-- /score, /healthz, /docs* ---> Application Load Balancer -> ECS Fargate task (FastAPI)
```

One CloudFront distribution fronts both the static frontend and the API so the browser only ever
talks to one HTTPS origin — the frontend calls relative paths (`fetch("/score")`), so there's no CORS
and no mixed-content issue even though the ALB itself only listens on HTTP.

This is the Terraform equivalent of what **ECS Express Mode** sets up for you through the console/CLI
wizard (VPC-less quick start, Fargate service, load balancer, public URL). Terraform doesn't expose a
dedicated "Express Mode" resource, so `infra/aws/main.tf` builds the same shape by hand: default VPC,
security groups, ALB, target group, ECS cluster/service/task definition.

## Run locally

Backend:

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8080
```

Frontend (proxies `/score` and `/healthz` to `localhost:8080`, see `frontend/vite.config.ts`):

```bash
cd frontend
npm install
npm run dev
```

Open the printed Vite URL (usually `http://localhost:5173`).

## Deploy to AWS

Region: `eu-central-1`, same account convention as risk-api. Requires Terraform >= 1.12.2 and admin
AWS credentials for the one-time setup below.

1. **State bucket**: if this AWS account already has a `tf-state-<account-id>` bucket from another
   project (e.g. risk-api), skip this step and reuse it — state keys are per-project
   (`risk-scoring-app/terraform.tfstate`). Otherwise:
   ```bash
   cd infra/aws-bootstrap && terraform init && terraform apply
   ```
2. **GitHub OIDC provider**: an AWS account can only have one OIDC provider for
   `token.actions.githubusercontent.com`. `infra/aws/github-oidc.tf` defaults to reusing an existing
   one (`create_oidc_provider = false`). If this is the first GitHub-OIDC project in the account, pass
   `-var="create_oidc_provider=true"` on the bootstrap `terraform apply` below instead.
3. Once the GitHub repo exists, get its numeric ID and set it in `infra/aws/github-oidc.tf`
   (the `sub` condition currently has a `REPLACE_WITH_REPO_ID` placeholder):
   ```bash
   curl -s https://api.github.com/repos/ovidiulazarescu/risk-scoring-app | grep '"id"'
   ```
4. **Bootstrap the stack** (once, from your machine): the deployer role must exist before Actions can
   assume it, and ECS needs an image in ECR before the service can start.
   ```bash
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   cd infra/aws
   terraform init -backend-config="bucket=tf-state-$ACCOUNT_ID"
   terraform apply \
     -target=aws_ecr_repository.risk_api \
     -target=aws_iam_role_policy.deployer_terraform \
     -target=aws_iam_role_policy.deployer_ecs

   # push a first image
   aws ecr get-login-password --region eu-central-1 | \
     docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com
   docker build --platform linux/amd64 -t $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/risk-scoring-app:bootstrap ./backend
   docker push $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/risk-scoring-app:bootstrap

   terraform apply -var="image_tag=bootstrap"
   ```
5. In the GitHub repo, add a repository **variable** named `AWS_ACCOUNT_ID` with your account ID
   (Settings > Secrets and variables > Actions > Variables).
6. **Generate the frontend lockfile once**, so CI's `npm ci` has something to install from:
   ```bash
   cd frontend && npm install
   ```
   Commit the resulting `package-lock.json`.
7. Push to `main`. The workflow builds and pushes the backend image, runs `terraform apply`, then
   builds the frontend and syncs it to S3, invalidating CloudFront. The app URL is the
   `cloudfront_domain_name` Terraform output (`https://<id>.cloudfront.net`).

Notes:
- ECS Fargate has no true scale-to-zero (desired count is 1, same tradeoff App Runner has vs. Cloud Run).
- The `/score` endpoint is public and unauthenticated, same as risk-api.
- No custom domain is configured; CloudFront's default `*.cloudfront.net` certificate is used.

## API

`POST /score` takes three fields and returns a score (300-850) and a risk band.

| Field | Type | Range |
|---|---|---|
| `credit_utilization` | float | 0.0 - 1.0 |
| `payment_history_score` | int | 0 - 100 |
| `debt_to_income` | float | 0.0 - 1.0 |

```bash
curl -X POST "$SERVICE_URL/score" \
  -H "Content-Type: application/json" \
  -d '{"credit_utilization": 0.1, "payment_history_score": 95, "debt_to_income": 0.15}'
```

Bands: `low` >= 700, `medium` >= 580, otherwise `high`. Health check: `GET $SERVICE_URL/healthz`.
Interactive API docs are served at `$SERVICE_URL/docs`.
