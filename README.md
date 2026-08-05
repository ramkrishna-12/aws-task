# Taskmaster — Technical Breakdown

## 1. Why does this exist?

This started as a take-home case study for a DevOps Engineer role: automate infrastructure
provisioning for a Spring Boot application using Docker, ECR, ECS, Terraform, and GitHub
Actions. The source repository provided had no actual application code — only build
config and an empty resources folder — so the first real task wasn't infrastructure at
all, it was noticing that nothing existed yet to deploy.

It later grew past the original scope: a Kubernetes (EKS) deployment path was added
alongside the existing ECS setup, specifically to close a recurring skill gap flagged
across several other job applications. So the project now serves two purposes —
a working case-study submission, and a reference implementation for "the same app,
two orchestrators."

## 2. What problem does it solve?

Absent this work, deploying this app would mean: manually clicking through the AWS
console to create a VPC, manually building and pushing Docker images from a laptop,
manually updating an ECS service, no automated tests gating what gets deployed, no
consistent image cleanup, and no visibility into whether the thing is actually healthy
after a deploy. Specifically, this solves:

- **Repeatability** — infrastructure defined in Terraform, not console clicks; anyone can
  reproduce the exact same environment from the code alone.
- **Deployment safety** — nothing reaches production without passing tests first, and a
  bad deploy automatically rolls itself back.
- **Unbounded growth** — ECR would otherwise accumulate every image ever pushed; a
  lifecycle policy caps it at the 5 most recent automatically.
- **Credential sprawl** — no long-lived AWS access keys stored anywhere; both GitHub
  Actions and (for the EKS path) individual pods authenticate via short-lived,
  narrowly-scoped identities.
- **Blind deployment** — before this, there was no way to know if the app was actually
  healthy post-deploy beyond "the deploy command didn't error." Now there's an automated
  smoke test plus real dashboards.

## 3. Architecture diagram

```
                                   Internet
                                      │
                     ┌────────────────┴────────────────┐
                     │                                  │
             ┌───────▼────────┐                ┌────────▼───────┐
             │  ALB (ECS path) │               │ ALB via Ingress │
             │  public subnets │               │ (EKS path, same │
             └───────┬────────┘               │  VPC/subnets)   │
                     │ SG: 80/443 from 0.0.0.0/0└────────┬───────┘
                     │                                  │
        ┌────────────▼────────────┐        ┌────────────▼────────────┐
        │   ECS Fargate Service    │        │   EKS Managed Node Group │
        │   (private subnets)      │        │   (private subnets)      │
        │   SG: 8080 from ALB only │        │   Pods, SG: from ALB only│
        └────────────┬────────────┘        └────────────┬────────────┘
                     │                                  │
                     └───────────────┬──────────────────┘
                                      │  pulls image
                             ┌────────▼────────┐
                             │   ECR Repository │
                             │  (5-image retain,│
                             │  immutable tags) │
                             └────────▲────────┘
                                      │ push (git-SHA tag)
                             ┌────────┴────────┐
                             │  GitHub Actions  │
                             │  (OIDC → AWS,     │
                             │   no static keys) │
                             └──────────────────┘

  Both compute paths also emit to:
    → CloudWatch Logs (awslogs driver / Fluent Bit)
    → CloudWatch Container Insights + Dashboard
    → /actuator/prometheus → self-hosted Prometheus/Grafana (optional)
```

## 4. AWS services used

| Service | Role |
|---|---|
| VPC (+ public/private subnets, IGW, NAT Gateways, route tables) | Network isolation — only the ALB is internet-facing |
| Security Groups | ALB (80/443 open) vs. app/pods (only reachable from the ALB's SG) |
| Application Load Balancer | Health-check-based routing, entry point for both ECS and EKS paths |
| ECS (Cluster, Task Definition, Service, Fargate launch type) | Primary container orchestration path |
| ECR | Image registry, with vulnerability scan-on-push and a 5-image lifecycle policy |
| IAM | ECS execution role, ECS task role, GitHub Actions OIDC-assumed deploy role, EKS IRSA roles |
| CloudWatch | Logs (structured app + access logs), Container Insights, a custom metrics dashboard, log-insights error panel |
| Application Auto Scaling | CPU target-tracking scaling for the ECS service |
| EKS (Cluster, Managed Node Group) | Alternate/secondary container orchestration path |
| S3 + DynamoDB *(prepared, not active)* | Intended remote Terraform state backend with locking — currently commented out; see Section 7 |

## 5. CI/CD flow

Two independent GitHub Actions workflows, deliberately not merged into one:

**`ci-cd.yml` (ECS path)** — triggered on push/PR to `main`:
1. `build-test` — compile, run unit/integration tests, build the jar, build (not push) the image. A failing test stops everything downstream.
2. `push` *(main branch only)* — authenticate to AWS via OIDC, build + tag the image with the git SHA, push to ECR.
3. `deploy` — pull the current ECS task definition, render a new revision pointing at the fresh image, deploy with `wait-for-service-stability`.
4. `smoke-test` — poll `/actuator/health` through the live ALB URL with retries.

**`k8s-deploy.yml` (EKS path)** — manually triggered (`workflow_dispatch`) with a `dev`/`prod` environment choice, so a routine push to `main` never accidentally deploys to both orchestrators at once:
1. `build-test-push` — same build/test/push logic as above, reusing the same ECR repository.
2. `deploy-eks` — update kubeconfig, `kustomize edit set image` to inject the freshly pushed tag, `kubectl apply -k`, wait on rollout status, then smoke-test through the Ingress-provisioned ALB.

Both paths share the same core principle: **nothing is pushed to a mutable tag**, every
deployed image is traceable to an exact commit, and every deploy ends with an actual
HTTP health check against the live system — not just "the orchestrator said it's done."

## 6. Terraform structure

```
terraform/
├── versions.tf        provider + backend config (S3 backend written, commented out)
├── variables.tf        all tunables — region, sizing, autoscaling bounds, retention counts
├── vpc.tf              VPC, public/private subnets, IGW, NAT gateways, route tables
├── security_groups.tf  ALB SG, ECS task SG
├── ecr.tf               repository, lifecycle policy (keep last 5), repo pull policy
├── iam.tf                ECS execution role, ECS task role
├── alb.tf                load balancer, target group, HTTP listener
├── ecs.tf                cluster, task definition, service, autoscaling target/policy
├── cloudwatch.tf        log group, custom dashboard
├── eks.tf                EKS cluster + managed node group (via terraform-aws-modules/eks)
├── eks-irsa.tf           OIDC provider wiring, app's own least-privilege IRSA role
├── outputs.tf            ALB DNS, ECR URL, cluster names, IRSA role ARN, kubeconfig command
└── terraform.tfvars.example
```

Design choices worth naming directly:
- **Flat structure, not modules** — one environment, one service; module abstraction would
  be premature until there's a second near-identical environment to justify it.
- **`lifecycle { ignore_changes = [...] }`** on the ECS task definition and service —
  Terraform owns infrastructure shape (CPU/memory/networking/roles); CI/CD owns which
  image is currently deployed. Without this, a routine `terraform apply` would silently
  revert a live deploy back to whatever's hardcoded in the `.tf` files.
- **Third-party modules used deliberately** (`terraform-aws-modules/eks`,
  `.../iam-role-for-service-accounts-eks`) rather than hand-rolling EKS/IRSA from raw
  resources — these are the de-facto standard modules for this; reinventing them adds
  risk without adding understanding.

## 7. Security decisions

- **Network isolation** — only the ALB sits in public subnets; every compute resource
  (ECS tasks, EKS nodes/pods) is in private subnets with no public IP, reachable only
  from the ALB's security group specifically — not a CIDR range.
- **Least-privilege, split IAM roles** — ECS execution role (pull image, write logs) is
  separate from the task role (app's own runtime AWS permissions); same split pattern
  applied to EKS via node IAM role vs. per-workload IRSA roles.
- **No static credentials anywhere** — GitHub Actions authenticates to AWS via OIDC
  (short-lived, repo-scoped tokens); EKS pods authenticate via IRSA. Nothing is stored
  as a long-lived AWS access key in either GitHub secrets or the cluster.
- **Immutable image tags + scan-on-push** — ECR rejects overwriting an existing tag, and
  every push is scanned for known vulnerabilities automatically.
- **Container hardening (Kubernetes path)** — pods run as non-root, with
  `readOnlyRootFilesystem: true` and all Linux capabilities dropped. *(Worth noting: the
  ECS task definition doesn't currently have equivalent hardening — a good improvement
  to backport for consistency.)*
- **Known, deliberate gaps — stated honestly rather than hidden:**
  - **No HTTPS/ACM listener** — only HTTP:80 is wired up; a real deployment needs a 443
    listener with an ACM cert and an HTTP→HTTPS redirect.
  - **No WAF** in front of either ALB.
  - **Local Terraform state** — the S3+DynamoDB backend is written but commented out, so
    there's currently no state locking; two concurrent `apply` runs could corrupt state.
  - **EKS API server has public access enabled** — should be restricted to specific
    CIDRs (office/VPN/CI runner ranges) rather than left fully open.

## 8. Cost considerations

- **NAT Gateways are the single biggest line item for a project this size** — one per AZ
  (two total) for redundancy, each billed hourly *plus* per-GB processed. For a low-traffic
  demo/case-study environment, this is disproportionately expensive relative to the actual
  app; a single shared NAT (accepting the AZ-failure trade-off) or NAT instances would cut
  this materially for a non-critical environment.
- **Fargate** bills per vCPU/memory-second while tasks run — no idle host cost the way
  EC2-backed ECS would have, but also no discount for sustained/reserved usage the way
  Savings Plans could provide at higher, predictable scale.
- **EKS control plane is a flat ~$0.10/hour regardless of usage** — this bills continuously
  whether or not anything is actually deployed to the cluster, on top of the EC2 node
  group's own hourly cost. **If the EKS path isn't actively being demoed or used, it should
  be torn down (`terraform destroy -target=module.eks`) rather than left running** — it's
  pure cost with zero benefit while idle.
- **ALB** has both an hourly charge and a per-LCU (load balancer capacity unit) charge —
  negligible at this traffic level, but two ALBs (one for ECS, one for the EKS Ingress) is
  double that fixed cost if both paths are ever running simultaneously.
- **ECR storage** is bounded intentionally by the 5-image lifecycle policy — without it,
  storage cost would grow unbounded with every single commit to `main`.
- **CloudWatch Logs** ingestion + storage cost is bounded by the 14-day retention setting
  (`log_retention_days` variable) — deliberately not "never expire," which would otherwise
  accumulate cost indefinitely for logs nobody will ever look at again.

## 9. Failure recovery

- **ECS deployment circuit breaker** — if a new deployment's tasks fail to reach a stable
  healthy state, ECS automatically rolls back to the last known-good task definition
  revision with no manual action required.
- **Kubernetes rolling update** — `maxUnavailable: 0` means capacity never drops during a
  rollout, and failing readiness probes pull a pod out of Service endpoints (not killing
  it, just stopping traffic to it) — a bad rollout can't silently take down the whole app.
- **Manual rollback (ECS)** — `aws ecs update-service --task-definition <family>:<older-revision>`
  points the service at any previous registered revision directly.
- **Manual rollback (Kubernetes)** — `kubectl rollout undo deployment/<name> -n taskmaster`,
  with `revisionHistoryLimit: 5` keeping the last 5 ReplicaSets available to roll back to.
- **The sharp edge worth knowing before it bites you**: ECR's lifecycle policy only keeps
  the 5 most recent images. If a rollback target is older than that, the image is already
  gone — and since the repo is tag-immutable, you can't just re-push the same tag. Recovery
  means rebuilding from that old commit and pushing under a *new* tag, then pointing the
  service at that.
- **Multi-AZ by design** — subnets, NAT gateways, and ECS/EKS compute all span two AZs, so
  a single AZ failure doesn't take the whole service down.
- **Terraform state issues** — a stuck lock (once the S3+DynamoDB backend is enabled) is
  resolved with `terraform force-unlock <id>` after confirming no other apply is actually
  running; drift from manual console changes is surfaced by `terraform plan` and resolved
  via `terraform import` or an explicit accept/revert decision.

## 10. Monitoring

- **CloudWatch Container Insights** — enabled on the ECS cluster, giving CPU/memory/network
  metrics per service and task without any extra instrumentation.
- **Custom CloudWatch Dashboard** (Terraform-managed) — ECS CPU/memory, ALB request count
  and latency, healthy/unhealthy target count, and a Logs Insights panel filtering for
  `ERROR` in application logs.
- **Spring Boot Actuator + Micrometer** — the app exposes `/actuator/health` (used by both
  the ALB target group and Kubernetes liveness/readiness probes) and `/actuator/prometheus`
  (Prometheus-format metrics: JVM heap, GC pause time, HTTP request rate/latency).
- **Self-hosted Prometheus + Grafana** — `monitoring/docker-compose.monitoring.yml` runs a
  local Prometheus/Grafana/cAdvisor stack for development; `taskmaster-dashboard.json` is
  directly importable into Grafana, covering JVM and container-level metrics.
- **Gap, honestly stated**: no CloudWatch Alarms or alerting are currently configured —
  dashboards exist, but nothing pages anyone automatically when a metric crosses a
  threshold. This is the single highest-value near-term addition (see Section 11).

## 11. Future improvements

Roughly in priority order:

1. **CloudWatch Alarms + notifications** (SNS → Slack/email/PagerDuty) on error rate, p95
   latency, and unhealthy host count — dashboards you have to remember to look at aren't
   monitoring, they're just a nicer way to find out something's been broken for an hour.
2. **Enable the S3+DynamoDB remote state backend** — currently the single biggest
   "would fail a real production readiness review" gap.
3. **HTTPS everywhere** — ACM certs + 443 listeners with HTTP→HTTPS redirects on both the
   ECS and EKS ALBs; add a WAF in front of at least the production one.
4. **`prevent_destroy` lifecycle blocks** on the ECR repo and VPC, to guard against an
   accidental `terraform destroy` taking out infrastructure and image history together.
5. **Move any future secrets to AWS Secrets Manager / SSM Parameter Store** rather than
   plain environment variables, referenced at runtime instead of baked into config.
6. **Harden the ECS task definition to match the Kubernetes deployment's security context**
   (non-root user, read-only root filesystem) — currently inconsistent between the two paths.
7. **Restrict the EKS API server's public endpoint** to specific CIDRs instead of open access.
8. **Multi-environment setup** (separate `dev`/`staging`/`prod` state files and variable
   sets) rather than the current single-environment configuration.
9. **Real integration tests** (Testcontainers-backed, once the app has an actual database
   layer) rather than the current thin smoke-level tests.
10. **Canary or blue/green deployments** — AWS CodeDeploy for the ECS path, or Argo Rollouts
    for the Kubernetes path — instead of the current straightforward rolling update, for
    workloads where a bad deploy needs to be caught on 5% of traffic, not 100%.