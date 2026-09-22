# risk-scoring-app

A small FastAPI risk-scoring service with a React frontend, deployed to **AWS ECS Fargate + CloudFront**
by Terraform, and shipped by GitHub Actions using keyless OIDC auth. Forked from
[risk-api](https://github.com/ovidiulazarescu/risk-api) (which runs the same API on Cloud Run and
App Runner).

## Layout

```
backend/                FastAPI service (same scoring logic as risk-api)
frontend/               React + Vite single-page form, with an SVG score gauge
infra/aws-bootstrap/    Terraform: S3 bucket for Terraform state
infra/aws/              Terraform: ECR, ECS Fargate + ALB, S3 + CloudFront,
                        GitHub OIDC provider + deployer role
.github/workflows/      deploy-aws.yml
```

## Architecture

```
Browser
   |
   v
CloudFront (single HTTPS domain, *.cloudfront.net)
   |-- default behavior ------------------> S3 bucket (built frontend, private, via OAC)
   `-- /score*, /healthz, /docs,
       /openapi.json, /redoc ------------> Application Load Balancer -> ECS Fargate task (FastAPI)
```

One CloudFront distribution fronts both the static frontend and the API so the browser only ever
talks to one HTTPS origin — the frontend calls relative paths (`fetch("/score")`), so there's no CORS
and no mixed-content issue even though the ALB itself only listens on HTTP.

Builds default VPC, security groups, ALB, target group, ECS cluster/service/task definition.

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

Requires Terraform >= 1.12.2 and admin
AWS credentials for the one-time setup below.

1. **State bucket**: if this AWS account already has a `tf-state-<account-id>` bucket from another
   project, skip this step and reuse it — state keys are per-project
   (`risk-scoring-app/terraform.tfstate`). Otherwise:
   ```bash
   cd infra/aws-bootstrap && terraform init && terraform apply
   ```
2. **GitHub OIDC provider**: an AWS account can only have one OIDC provider for
   `token.actions.githubusercontent.com`. This stack creates and owns it
   (`create_oidc_provider` defaults to `true`). If the account already has one from another project
   (e.g. risk-api), pass `-var="create_oidc_provider=false"` so Terraform looks the existing one up
   instead of failing with `EntityAlreadyExists`.
3. The GitHub owner and repo IDs are already filled into the `sub` condition in
   `infra/aws/github-oidc.tf`. GitHub issues the **immutable-ID** form of the subject claim
   (`repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main`), not the plain
   `repo:<owner>/<repo>:ref:...` form, and the trust policy has to match it exactly. If the repo is
   ever deleted and recreated the IDs change, so update the condition and reapply with
   `terraform apply -target=aws_iam_role.github_actions_deployer`.
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
6. *Optional* — **pin frontend installs**. There is no `frontend/package-lock.json`, so CI runs
   `npm install` and resolves the `^` ranges in `package.json` fresh on every run. To pin them,
   generate a lockfile, commit it, and change the workflow's `npm install` to `npm ci`:
   ```bash
   cd frontend && npm install
   ```
7. Push to `main`. The workflow builds and pushes the backend image, runs `terraform apply`, then
   builds the frontend and syncs it to S3, invalidating CloudFront. The app URL is the
   `cloudfront_domain_name` Terraform output (`https://<id>.cloudfront.net`).

Notes:
- **CI cannot repair its own credentials.** The workflow assumes the deployer role *before* it runs
  `terraform apply`, so any change to that role's trust policy or IAM permissions has to be applied
  from your machine first — otherwise every run keeps failing against the old config. Apply those
  with `-target` rather than a bare `terraform apply`, since the ECS service waits for steady state
  against an image tag that may not exist yet.
- When debugging OIDC, note that AWS returns the same `Not authorized to perform
  sts:AssumeRoleWithWebIdentity` whether the trust policy rejected the token *or* the role doesn't
  exist — so a trust-policy change that appears to do nothing may mean the role was never created.
- The `/score` endpoint is public and unauthenticated.
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
