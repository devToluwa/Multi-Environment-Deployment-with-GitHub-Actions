# SOP: Multi-Environment Deployment with GitHub Actions

**Project:** Multi-Environment Deployment with GitHub Actions  
**Author:** devToluwa  
**Version:** 1.0  
**Status:** Complete

---

## Purpose

This SOP documents the operational procedures for managing and maintaining the multi-environment deployment pipeline built in Project 5 of the 100 DevOps Projects curriculum. It covers how to trigger deployments, approve production releases, verify environment health, troubleshoot common failures, and tear down infrastructure.

---

## Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` returns your account)
- Terraform installed and initialised in `terraform/`
- Access to the GitHub repo with Actions permissions
- Docker Desktop running (for local builds only)

---

## 1. Triggering a Deployment

Deployments trigger automatically on every push to `main`.

```bash
git add .
git commit -m "your commit message"
git push origin main
```

The pipeline will:
1. Build and push a new Docker image to ECR tagged with the git SHA
2. Deploy automatically to dev
3. Deploy automatically to staging (after dev passes)
4. Pause and wait for production approval

---

## 2. Approving a Production Deployment

1. Go to the GitHub repo → **Actions** tab
2. Click the in-progress pipeline run
3. You will see a yellow banner on the **Deploy to Production** job saying "Waiting for review"
4. Click **Review deployments**
5. Select `prod` and click **Approve and deploy**

The pipeline will then deploy to production and run the smoke test.

---

## 3. Verifying Environment Health

Run the health check script to confirm all three environments are live:

```bash
bash secrets/check-envs.sh
```

Expected output:

```
Environment: dev    → {"environment":"dev","status":"healthy"}
Environment: staging → {"environment":"staging","status":"healthy"}
Environment: prod   → {"environment":"prod","status":"healthy"}
```

To manually check a single environment:

```bash
# Get task ARN
aws ecs list-tasks \
  --cluster multi-env-deploy \
  --service-name multi-env-deploy-<ENV> \
  --query 'taskArns[0]' \
  --output text

# Get ENI ID from task
aws ecs describe-tasks \
  --cluster multi-env-deploy \
  --tasks <TASK_ARN> \
  --output json | grep -A1 '"networkInterfaceId"' | grep '"value"' | cut -d'"' -f4

# Get public IP from ENI
aws ec2 describe-network-interfaces \
  --network-interface-ids <ENI_ID> \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text

# Hit health endpoint
curl http://<PUBLIC_IP>:5000/health
```

---

## 4. Checking Running Task Count

```bash
aws ecs describe-services \
  --cluster multi-env-deploy \
  --services multi-env-deploy-<ENV> \
  --query 'services[0].runningCount'
```

Should return `1` for each environment. If it returns `0`, see Section 6.

---

## 5. Checking ECS Service Events

When a deployment fails or a container won't start:

```bash
aws ecs describe-services \
  --cluster multi-env-deploy \
  --services multi-env-deploy-<ENV> \
  --query 'services[0].events[0:5]'
```

---

## 6. Troubleshooting

### Container won't start, empty image tag
**Symptom:** ECS events show `failed to normalize image reference "...multi-env-deploy:"`  
**Cause:** Task definition has an empty image tag  
**Fix:**
```bash
# Register a new task definition revision with a real image tag
aws ecs register-task-definition \
  --family multi-env-deploy-<ENV> \
  --requires-compatibilities FARGATE \
  --network-mode awsvpc \
  --cpu 256 \
  --memory 512 \
  --execution-role-arn arn:aws:iam::<ACCOUNT_ID>:role/multi-env-deploy-ecs-task-execution \
  --container-definitions "[{\"name\":\"multi-env-deploy\",\"image\":\"<ECR_URL>:<IMAGE_TAG>\",\"portMappings\":[{\"containerPort\":5000,\"protocol\":\"tcp\"}],\"environment\":[{\"name\":\"ENVIRONMENT\",\"value\":\"<ENV>\"}],\"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/multi-env-deploy/<ENV>\",\"awslogs-region\":\"us-east-1\",\"awslogs-stream-prefix\":\"ecs\"}}}]"

# Point the service at the new revision
aws ecs update-service \
  --cluster multi-env-deploy \
  --service multi-env-deploy-<ENV> \
  --task-definition multi-env-deploy-<ENV>:<REVISION_NUMBER> \
  --force-new-deployment
```

### OIDC authentication failure
**Symptom:** `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`  
**Checks:**
- Workflow has `permissions: id-token: write` at the top level
- IAM role trust policy `sub` condition matches exact GitHub repo casing
- `AWS_ROLE_ARN` and `AWS_REGION` secrets are set in GitHub repo settings

### Pipeline stuck deploying
**Symptom:** Workflow hangs for 20+ minutes at Deploy to ECS step  
**Cause:** `wait-for-service-stability: true` waiting on a container that cannot start  
**Fix:** Check ECS service events to find root cause. Set `wait-for-service-stability: false` temporarily to unblock the pipeline.

### IAM permission denied
**Symptom:** `AccessDeniedException` on any AWS CLI call in the workflow  
**Fix:** Add the missing action to `aws_iam_role_policy.github_actions` in `terraform/iam.tf` and run `terraform apply`

---

## 7. Viewing Container Logs

```bash
aws logs get-log-events \
  --log-group-name /ecs/multi-env-deploy/<ENV> \
  --log-stream-name ecs/multi-env-deploy/<TASK_ID> \
  --limit 50
```

To find the log stream name:
```bash
aws logs describe-log-streams \
  --log-group-name /ecs/multi-env-deploy/<ENV> \
  --order-by LastEventTime \
  --descending \
  --limit 1
```

---

## 8. Updating Infrastructure

Any changes to Terraform files require:

```bash
cd terraform
terraform plan   # review changes
terraform apply  # apply changes
```

Never manually edit AWS resources that are managed by Terraform changes will be overwritten on the next `terraform apply`.

---

## 9. Teardown

To destroy all AWS infrastructure and stop all charges:

```bash
cd terraform
terraform destroy
```

Type `yes` when prompted. This removes:
- ECR repository and all images
- ECS cluster, services, and task definitions
- IAM roles and policies
- Security groups
- CloudWatch log groups

> Note: Tear down when the project is no longer in use. Three Fargate tasks running 24/7 cost approximately $0.72/day.

---

## 10. Known Issues & Limitations

- **No load balancer:** Each ECS task gets a public IP directly. IPs change on every redeploy. A production setup would use an ALB with a stable DNS name.
- **No rollback:** If a deployment fails the smoke test, the pipeline fails but the service may still be running the broken task definition. Manual intervention is required.
- **Smoke test is basic:** The smoke test only checks that a task is running, not that the HTTP endpoint is actually responding. This was a deliberate tradeoff to avoid networking complexity without a load balancer.
- **Single region:** All environments run in `us-east-1`. No multi-region failover.