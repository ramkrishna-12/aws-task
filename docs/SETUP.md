# Taskmaster — Infrastructure & CI/CD Setup

## 0. What was fixed before this build was possible

The upstream repo (`nreddywellness360/taskmaster`) shipped with **no application
code** — `build.gradle` *and* `pom.xml` both present but `src/main/java` was empty,
so there was nothing to compile, test, or containerize. Before touching Docker or
Terraform, this was resolved by:

- Removing `pom.xml` and standardizing on **Gradle** (the wrapper was already present).
- Adding `TaskmasterApplication.java` (entry point) and `TaskController.java`
  (`GET /` and `GET /api/tasks`) so there's an actual service to deploy.
- Adding Spring Boot **Actuator** + **Micrometer Prometheus registry**, exposing
  `/actuator/health` (ALB + ECS health checks) and `/actuator/prometheus` (metrics scraping).
- Adding a real test class (`TaskmasterApplicationTests`) so the CI pipeline's
  test stage has something to actually run.
- Enabling **layered jars** (`bootJar { layered { enabled = true } }`) so the
  Dockerfile can copy dependency layers separately from application code for
  much better build-cache reuse and a smaller effective image.

## 1. Architecture

```
Internet
   │
   ▼
[ ALB : public subnets ] ── security group: 80/443 from 0.0.0.0/0
   │
   ▼
[ ECS Fargate Service : private subnets ] ── security group: 8080 from ALB only
   │
   ├── pulls image from ── [ ECR repo, lifecycle: keep last 5 images ]
   └── logs/metrics to ── [ CloudWatch Logs + Container Insights + Dashboard ]
```

- **Fargate**, not EC2-backed ECS: no host patching, scales per-task, matches the
  "efficient / low-maintenance" evaluation criteria.
- Tasks run in **private subnets** with no public IP; only the ALB is internet-facing.
- **ECR image tags are immutable** — every push is a new, traceable, rollback-safe
  artifact (the git SHA), never an overwritten `:latest`.

## 2. One-time setup

### 2.1 Bootstrap AWS OIDC for GitHub Actions (no static AWS keys in CI)

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Create an IAM role trusting that provider, scoped to this repo, with permissions
for ECR push, `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`,
`ecs:UpdateService`, and `iam:PassRole` on the two ECS roles Terraform creates.
Put its ARN in the repo secret `AWS_DEPLOY_ROLE_ARN`.

### 2.2 Provision infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # adjust as needed
terraform init
terraform plan
terraform apply
```

Note the outputs: `ecr_repository_url`, `alb_dns_name`, `ecs_cluster_name`, `ecs_service_name`.

### 2.3 Wire up GitHub Actions

Repo secrets:
- `AWS_DEPLOY_ROLE_ARN` — from 2.1
- `APP_URL` — `http://<alb_dns_name>` from the Terraform output (used by the smoke-test job)

Confirm the `env:` block at the top of `.github/workflows/ci-cd.yml` matches your
Terraform naming (`ECS_CLUSTER`, `ECS_SERVICE`, `ECS_TASK_FAMILY`, `ECR_REPOSITORY`).

### 2.4 First image push

The ECS service needs at least one real image in ECR before it can start tasks
(Terraform's task definition references `:latest` as a placeholder). Push once
manually, or just merge to `main` — the pipeline's `push` job will build and
push the first real image, and `deploy` will pick it up.

## 3. How the pipeline satisfies "keep only the last 5 images"

Retention is enforced by an **ECR lifecycle policy** (`terraform/ecr.tf`,
`aws_ecr_lifecycle_policy`), not by CI scripting: once more than
`ecr_max_image_count` (default 5) images exist in the repo, AWS itself expires
the oldest ones on a schedule. This is more reliable than a workflow step
calling `aws ecr batch-delete-image`, since it applies even to images pushed
outside CI, and can't be skipped by a partially-failed workflow run.

## 4. Monitoring

- **CloudWatch**: Container Insights is enabled on the ECS cluster; a
  `aws_cloudwatch_dashboard` (Terraform) ships CPU/memory, ALB request count,
  latency, healthy/unhealthy host count, and a log-insights error panel out of the box.
- **Prometheus/Grafana**: the app exposes `/actuator/prometheus`.
  `monitoring/docker-compose.monitoring.yml` runs a local Prometheus + Grafana +
  cAdvisor stack for development (`docker compose -f monitoring/docker-compose.monitoring.yml up --build`,
  Grafana at `localhost:3000`, default creds `admin` / `admin`).
  `monitoring/grafana/dashboards/taskmaster-dashboard.json` is importable directly
  into Grafana (Dashboards → Import → Upload JSON).
- For a production self-hosted Prometheus scraping real ECS tasks (rather than the
  local compose stack), run Prometheus as its own ECS service using the `ecs_sd_config`
  service discovery mechanism, or point Grafana at the CloudWatch data source directly
  and skip self-hosted Prometheus entirely — simpler to operate, no extra service to maintain.

## 5. Local development

```bash
./gradlew bootRun          # run the app directly
./gradlew test             # run tests
docker build -t taskmaster:local .
docker run -p 8080:8080 taskmaster:local
curl localhost:8080/actuator/health
```

## 6. Rolling back a bad deploy

```bash
# List recent revisions
aws ecs list-task-definitions --family-prefix taskmaster-prod-task --sort DESC

# Point the service at a previous, known-good revision
aws ecs update-service \
  --cluster taskmaster-prod-cluster \
  --service taskmaster-prod-service \
  --task-definition taskmaster-prod-task:<previous-revision-number>
```
The ECS deployment circuit breaker (`terraform/ecs.tf`) also auto-rolls-back
failed deployments without manual intervention.
