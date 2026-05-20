# Multi-Environment Deployment with GitHub Actions

**Stack:** Python · Flask · Docker · GitHub Actions · AWS ECR · AWS ECS Fargate · Terraform

---

## What This Project Does

Builds a CI/CD pipeline that automatically deploys a containerised Python app through three isolated environments; dev, staging, and production, using GitHub Actions. Each environment runs as its own ECS Fargate service on AWS, with environment-specific configuration injected at runtime. Production deployments require manual approval before proceeding.

---

## Architecture

```
Push to main
     ↓
GitHub Actions -> Build Docker image
     ↓
Push image to AWS ECR (tagged with git SHA)
     ↓
Deploy to DEV (automatic)
     ↓ smoke test passes
Deploy to STAGING (automatic)
     ↓ smoke test passes
Deploy to PRODUCTION (requires manual approval)
     ↓ smoke test passes
All three environments live
```

---

## Stack Breakdown

| Component | What it does |
|---|---|
| **Flask** | Minimal Python web app with `/` and `/health` endpoints |
| **Docker** | Packages the app into a portable container image |
| **AWS ECR** | Stores Docker images (one repo, images tagged by git SHA) |
| **AWS ECS Fargate** | Runs containers serverlessly; no EC2 instances to manage |
| **Terraform** | Provisions all AWS infrastructure as code |
| **GitHub Actions** | Orchestrates the full CI/CD pipeline |
| **GitHub Environments** | Enforces approval gates and stores env-specific secrets |

---

## Project Structure

```
multi-env-deploy/
├── app/
│   ├── app.py               # Flask app with / and /health endpoints
│   └── requirements.txt
├── terraform/
│   ├── main.tf              # AWS provider config
│   ├── variables.tf         # Input variables
│   ├── terraform.tfvars     # Variable values (gitignored)
│   ├── ecr.tf               # ECR repository
│   ├── ecs.tf               # ECS cluster, task definitions, services
│   ├── iam.tf               # GitHub Actions OIDC role, ECS execution role
│   └── outputs.tf           # ECR URL, cluster name, role ARN
├── .github/
│   └── workflows/
│       ├── ci.yml           # Main pipeline: build + chain deploys
│       └── deploy.yml       # Reusable deploy workflow
├── secrets/
│   └── check-envs.sh        # Script to get IPs and health check all envs
├── Dockerfile
└── .gitignore
```

---

## How the Pipeline Works

### `ci.yml` Main workflow, triggers on push to `main`

1. **Build:** checks out code, authenticates with AWS via OIDC, builds Docker image tagged with `${{ github.sha }}`, pushes to ECR
2. **Deploy Dev:** calls `deploy.yml` with `environment: dev`
3. **Deploy Staging:**runs after dev succeeds, calls `deploy.yml` with `environment: staging`
4. **Deploy Prod:** runs after staging succeeds, calls `deploy.yml` with `environment: prod`, pauses for human approval

### `deploy.yml` Reusable workflow, called by `ci.yml`

1. Authenticates with AWS
2. Downloads current task definition from ECS
3. Renders a new task definition with the new image tag
4. Deploys to ECS service
5. Smoke test, verifies at least one task is running in the service

---

## Key Concepts Demonstrated

**OIDC Authentication:** GitHub Actions authenticates with AWS using OpenID Connect instead of storing long-lived AWS access keys. GitHub proves its identity, AWS issues temporary credentials.

**Reusable Workflows:** `deploy.yml` is called three times with different inputs rather than duplicating the deploy logic.

**GitHub Environments:** Each environment (dev, staging, prod) has its own secrets and protection rules. Production requires a required reviewer to approve before the job runs.

**Image Tagging by Git SHA:** Every image is tagged with the exact commit that built it. You always know what code is running in each environment.

**Terraform for Infrastructure:** The `for_each` pattern creates dev, staging, and prod ECS services from a single resource block.

---

## Setup

### Prerequisites
- AWS account with CLI configured (`aws configure`)
- Terraform installed
- Docker installed
- GitHub repo with Actions enabled

### 1. Provision AWS infrastructure

```bash
cd terraform
terraform init
terraform apply
```

Note the outputs, you'll need `ecr_repository_url` and `github_actions_role_arn`.

### 2. Configure GitHub repo secrets

Go to **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | ARN from Terraform output |
| `AWS_REGION` | `us-east-1` |

### 3. Create GitHub Environments

Go to **Settings → Environments** and create: `dev`, `staging`, `prod`

For `prod` enable **Required reviewers** and add yourself.

### 4. Push to main

```bash
git push origin main
```

Watch the pipeline run in the Actions tab.

---

## Health Check Script

To get the public IP and health status of all three running environments:

```bash
bash secrets/check-envs.sh
```

Expected output:
```
Environment: dev    → {"environment":"dev","status":"healthy"}
Environment: staging → {"environment":"staging","status":"healthy"}
Environment: prod   → {"environment":"prod","status":"healthy"}
```

---

## Teardown

To avoid ongoing AWS charges, destroy all infrastructure when done:

```bash
cd terraform
terraform destroy
```

Type `yes` when prompted. This removes all ECS services, task definitions, ECR repo, IAM roles, security groups, and CloudWatch log groups.

---

## Issues & Fixes Encountered

### 1. OIDC Authentication Failure
**Error:** `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`  
**Cause:** Multiple issues missing `permissions: id-token: write` in workflow, incorrect repo name casing in IAM trust policy, secrets not properly saved  
**Fix:** Added `permissions` block to both `ci.yml` and `deploy.yml`, corrected trust policy casing to exactly match GitHub repo URL, hardcoded role ARN temporarily to isolate the secrets issue

### 2. Empty Image Tag on ECS Task Definitions
**Error:** `failed to normalize image reference "...multi-env-deploy:"`, colon with nothing after it  
**Cause:** Terraform created initial task definitions before any Docker image existed in ECR, leaving an empty image tag  
**Fix:** Manually registered new task definition revisions with a valid image tag using `aws ecs register-task-definition`, then updated the ECS services to use the new revisions

### 3. ECS Service Stuck Deploying
**Symptom:** GitHub Actions workflow hung for 20+ minutes at "Deploy to ECS" step  
**Cause:** `wait-for-service-stability: true` combined with containers that couldn't start (due to the empty tag issue)  
**Fix:** Set `wait-for-service-stability: false` and moved health verification to the smoke test step

### 4. Smoke Test Failing, Cannot Connect to Container
**Error:** `curl: (7) Failed to connect to port 5000`  
**Cause:** Curling the task's public IP directly is unreliable, tasks get new IPs on redeploy, and the 30s sleep wasn't enough  
**Fix:** Replaced the curl-based smoke test with an ECS `runningCount` check, verifies at least one task is running rather than trying to reach it over HTTP

### 5. Gunicorn Cannot Find App Module
**Error:** `ModuleNotFoundError: No module named 'app.app'`  
**Cause:** Dockerfile CMD used wrong syntax,`app.app` instead of `app:app`  
**Fix:** Changed Dockerfile CMD to `["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]`

### 6. IAM Missing Permissions
**Error:** `AccessDeniedException: not authorized to perform ecs:ListTasks`  
**Cause:** Initial IAM policy didn't include `ecs:ListTasks`, `ecs:DescribeTasks`, or `ec2:DescribeNetworkInterfaces`  
**Fix:** Added missing actions to the GitHub Actions IAM role policy in `iam.tf` and re-ran `terraform apply`