# Azure Hello World - Platform Demo

A working deployment of a stateless app on Azure Container Apps with Terraform, CI/CD via GitHub Actions, and infrastructure-as-code practices. This demonstrates core patterns: managed identity authentication, automated deployment, cost tracking, and supply chain security.

## What's Here

A public-facing HTTP service (`/healthz` for liveness, `/` returns a simple response) deployed to Azure Container Apps with:
- Terraform infrastructure (bootstrap + workload layers)
- GitHub Actions CI/CD (automated plan → approval → deploy workflow)
- Cost visibility (Infracost in every change)
- Supply chain scanning (Snyk for image vulnerabilities)
- Managed identity auth (no keys stored anywhere)
- Approval gating (manual approval required before production apply)

## High-Level Architecture

```
Internet Users
    │ HTTPS
    ↓
Public Container App (2-5 replicas, autoscaling)
    ├─→ Container Registry (pulls images)
    ├─→ Log Analytics (logs, 30-day retention)
    ├─→ Application Insights (traces, exceptions, APM)
    ├─→ Monitor Action Group (alerts → email)
    └─→ Managed Identity (Azure AD auth)
        
GitHub Actions CI/CD
    ├─→ Validate (format, syntax, security)
    ├─→ Build & Push Image
    ├─→ Scan Image (Snyk)
    └─→ Plan & Cost Estimate (Infracost)
        └─→ Approval Gate
            └─→ Deploy to App via Terraform
```
## Design Decisions

### Why Container Apps Instead of Kubernetes?
We have a stateless HTTP service with no special requirements. Kubernetes adds operational overhead (cluster management, node patches, complexity) that isn't justified here. Container Apps gives us 80% of the features with 20% of the complexity—autoscaling, managed updates, integrated monitoring.

### Application Design: Wrapping a From-Scratch Binary in HTTP

The assignment required deploying `library/hello-world` - a minimal from-scratch image with just a static binary (`/hello`) and no shell or runtime.

**Problem:** A from-scratch binary isn't accessible over HTTP. It needs a listening port and HTTP handler.

**Solution:** I built a Python HTTP wrapper that:
1. Runs a Python 3.12-slim base (small, production-grade)
2. Extracts the official `/hello` binary via multi-stage Docker build
3. Wraps it in a minimal HTTP server that serves:
   - `GET /` → Runs `/hello` and returns its output over HTTP
   - `GET /healthz` → Health probe for Container App liveness checks

**Why this approach?**
- **Uses the exact official image** (satisfies the assignment requirement)
- **Minimal attack surface** (`/hello` is static and from an official source)
- **No runtime overhead** (subprocess call to a binary is negligible)
- **Production-safe headers** (CSP, nosniff, referrer policy on every response)

The Dockerfile uses a multi-stage build: it pulls the `/hello` binary from `library/hello-world:latest` in the first stage, then discards that entire image layer and copies only the binary into a fresh `python:3.12-slim` base. This avoids bloating the final image.

### Why Managed Identity, Not Stored Keys?
Storing keys in GitHub (even encrypted) is a liability. Managed identity means Azure AD authenticates the app automatically—no credentials to rotate, revoke, or accidentally leak. OIDC for GitHub Actions follows the same principle: GitHub gets a time-limited token, not a long-lived secret.

### Why Split Resource Groups?
- `rg-tfstate-prod-uks-001`: Terraform state storage (long lifecycle, rarely changes)
- `rg-platform-cicd-prod-uks-001`: CI/CD infrastructure (managed identity, ACR, Log Analytics)
- `rg-helloworld-prod-uks-001`: Application and runtime resources (updated frequently)

This separation reduces blast radius—if something goes wrong with the app, it doesn't touch the state storage or CI/CD infrastructure. Different teams could own these independently.

### Why Infracost in CI/CD?
Infrastructure changes should show their cost impact before they're deployed. If someone accidentally changes `max_replicas` from 5 to 20, Infracost posts "$54/month cost increase" in the PR. Catch expensive mistakes early.

### Why Snyk for Image Scanning?
Container images inherit vulnerabilities from base images and dependencies. Snyk scans every image we build and blocks deployment if critical CVEs are found. It prevents shipping known-vulnerable code.

## Terraform Structure: Bootstrap vs. Workload

We split Terraform into two layers: **bootstrap** and **workload**. Bootstrap creates the foundation (Terraform state storage, container registry, managed identities, CI/CD auth) that everything else depends on. Workload deploys the application on top of that foundation. This separation means bootstrap runs once and rarely changes, while workload can be deployed and updated frequently without touching shared infrastructure. It also reflects reality: on Day 0, you have no state storage yet, so you must store bootstrap state locally, migrate it to remote storage, then deploy workloads with remote state. This reduces the blast radius and separates concerns.

## Demo Deployment vs. Production Hardening

### Demo (This Repository)

**What we're building:**
- Stateless HTTP service on Azure Container Apps
- Public ingress (no network isolation)
- ACR Basic tier (public, no geo-replication)
- Single region (UK South) with optional zone redundancy
- Application Insights & Log Analytics with 90/30-day retention
- Managed identity auth (no stored secrets)
- Snyk image scanning in CI/CD
- Infracost cost estimates in every PR

**Why this is not production-ready:**
- **No network isolation**: The app is publicly accessible. For regulated data, you'd need a VNet with private subnets and private endpoints.
- **No WAF**: Azure Front Door Premium with WAF (~$330/month base) would add DDoS protection and rate limiting. For a public demo with no data, it's overkill.
- **ACR is public**: For production, you'd use private endpoints so images never touch the public internet.
- **Single region**: Regional Azure outage = full downtime. Production requires multi-region DR.
- **No encryption at rest**: Terraform state uses default encryption. Production should use CMK (customer-managed keys).

**Cost:** ~$34/month (or ~$55/month at peak load with 5 replicas)

This is intentional. The demo shows the *patterns* (managed identity, automation, cost tracking, security scanning) without over-engineering for a workload that handles no sensitive data.

### Production Hardening (If Handling Customer Data)

**Network Security:**
- VNet with private subnets (`10.0.0.0/16` with `/24` delegated to Container Apps)
- Private endpoints for ACR and Storage Account (no public IP exposure)
- Private DNS zones (`privatelink.azurecr.io`, `privatelink.blob.core.windows.net`)
- Network Security Groups (NSGs) restricting lateral movement
- Azure Firewall or WAF at the perimeter

**High Availability & Disaster Recovery:**
- **Zone redundancy**: Container App Environment across 3 AZs (`zone_redundancy_enabled = true`)
- **Multi-region**: Active-Active or Active-Passive DR via Azure Front Door Premium
- **Geo-redundant storage**: GRS or RA-GRS for Terraform state (automatic failover to paired region)
- **ACR Premium**: Geo-replication to secondary region (e.g., UK South + West Europe)
- **Health checks & monitoring**: Azure Monitor alerts on unhealthy instances

**Secrets & Identity:**
- Azure Key Vault for runtime secrets (API keys, DB passwords, etc.)
- Managed Identity with least-privilege roles (Contributor only where necessary)
- No keys in GitHub; OIDC federated auth for CI/CD

**Data Protection:**
- Encryption at rest: Customer-managed keys (CMK) for state and logs
- Encryption in transit: TLS 1.2+ everywhere
- Blob versioning & soft delete (7-day retention) on Storage Account
- Application Insights & Log Analytics exports to separate storage for long-term audit trail

**Compliance & Scanning:**
- Container Registry content trust (cryptographic signing of images)
- Policy enforcement (Azure Policy) for resource naming, tagging, compliance
- Audit logging (Azure Monitor Activity Log)
- Regular vulnerability scanning (Snyk in CI/CD + runtime scanning)
- SOC 2 / HIPAA / PCI-DSS compliance as needed

**Self-Hosted CI/CD:**
- If ACR is private and sensitive workloads require network isolation, deploy self-hosted GitHub Actions runners as Azure Container Apps (using KEDA for ephemeral scaling). This keeps the CI/CD pipeline inside the VNet, preventing images from traversing the public internet.
- Runner authenticates to private ACR via managed identity and push/pull images privately.

**Cost:** ~$150–$250/month (depending on DR strategy: ~$34 base + ~$110 for Active-Active, or ~$20 for Active-Passive)

---

The difference: **Demo** prioritizes simplicity and cost. **Production** prioritizes security, compliance, and resilience. Both use the same Terraform patterns—production just enables more features and isolation.

## How to Run the Demo deployment

### Prerequisites
- Azure CLI (latest)
- Terraform >= 1.6.0
- Git
- GitHub CLI (`gh`)
- An Azure subscription with Owner/Contributor permissions

### 1. Set Up OIDC Federated Credentials

GitHub Actions authenticates to Azure via OIDC (no stored credentials).

```bash
REPO_OWNER="CipLabs"
REPO_NAME="azure-platform-demo"
REPO_ID="762649821"  # Get this from: gh repo view --json databaseId
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

az identity federated-credential create \
  --name github-oidc \
  --identity-name id-ghrunner-prod-uks-001 \
  --resource-group rg-platform-cicd-prod-uks-001 \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:$REPO_OWNER/$REPO_NAME@$REPO_ID:environment:production" \
  --audiences "api://AzureADTokenExchange"
```

### 2. Add GitHub Secrets and Variables

Go to repo Settings → Secrets and variables → Actions.

**Secrets:**
```
SNYK_TOKEN              (from Snyk account)
INFRACOST_API_KEY       (from Infracost dashboard)
```

**Variables:**
```
AZURE_CLIENT_ID         (from bootstrap outputs)
AZURE_TENANT_ID         (from bootstrap outputs)
AZURE_SUBSCRIPTION_ID   (your subscription ID)
ACR_NAME                (from bootstrap outputs)
TFSTATE_RESOURCE_GROUP  rg-tfstate-prod-uks-001
TFSTATE_STORAGE_ACCOUNT (from bootstrap outputs)
```

### 3. Create Local Variables File for Workload

For local development, create a `.tfvars` file with your subscription and registry details. You'll need this before deploying the workload:

```bash
mkdir -p terraform/workloads/helloworld/envs

cat > terraform/workloads/helloworld/envs/prod.tfvars <<EOF
subscription_id           = "$(az account show --query id -o tsv)"
container_registry_name   = "acrplaceholder"  # Replace after bootstrap completes
image_tag                 = "latest"
EOF
```

After you deploy bootstrap (step 5), update `container_registry_name` with the actual ACR name from bootstrap outputs. This file is in `.gitignore`—it's only for local testing. GitHub Actions provides these values via `-var` flags instead (from GitHub Variables).

### 4. Deploy Bootstrap Infrastructure

```bash
cd terraform/bootstrap
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Save outputs for step 2
terraform output -json > outputs.json
```

This creates:
- Storage account with Terraform state
- ACR (container registry)
- Managed identities for the app and CI/CD
- Application Insights and Log Analytics workspace

### 5. Configure Remote State

After bootstrap, migrate Terraform state to the remote backend:

```bash
cd terraform/bootstrap

cat > backend.conf <<EOF
resource_group_name      = "rg-tfstate-prod-uks-001"
storage_account_name     = "$(terraform output -raw tfstate_storage_account)"
container_name           = "tfstate"
key                      = "bootstrap-prod.tfstate"
use_azuread_auth         = true
use_oidc                 = true
client_id                = "$(terraform output -raw github_deployer_client_id)"
tenant_id                = "$(terraform output -raw tenant_id)"
subscription_id          = "$(terraform output -raw subscription_id)"
EOF

terraform init -backend-config=backend.conf -upgrade
```

### 6. Update Workload Variables

Now that bootstrap is complete, update the tfvars file with the actual ACR name:

```bash
ACR_NAME=$(cd terraform/bootstrap && terraform output -raw helloworld_acr_name)

sed -i "s/acrplaceholder/$ACR_NAME/" terraform/workloads/helloworld/envs/prod.tfvars
```

### 7. Push to GitHub and Trigger CI/CD

After bootstrap and local variable setup, push your code to trigger the CI/CD pipeline:

```bash
git add terraform/workloads/helloworld/
git commit -m "Deploy hello-world application"
git push origin main
```

The workflow runs in two stages:

**Stage 1: Plan & Validation** (automatic, runs immediately)
- Build and scan container image (Snyk blocks deployment on critical CVEs)
- Run `terraform plan` on the workload
- Post cost estimate (Infracost)
- Post plan output for review

**Stage 2: Approval & Apply** (manual, requires approval)
- A reviewer must approve the deployment via GitHub
- Navigate to: Actions → Latest workflow run → Review deployments
- Click "Approve and deploy" to proceed with `terraform apply`
- Once approved, the Container App is updated with the new image

This approval gate prevents accidental deployments and ensures human review before infrastructure changes hit production.

**Monitor the deployment:**
```bash
# Watch the GitHub Actions workflow
gh run list --workflow=cd-deploy.yml --limit 1 --watch

# Or view in browser
open "https://github.com/CipLabs/azure-platform-demo/actions"
```

**Note:** The `.tfvars` file you created is in `.gitignore` and won't be committed. CI/CD uses GitHub Variables instead (via `-var` flags), which is the production-safe approach.

### 8. Test the Deployment

```bash
# Get the Container App URL
FQDN=$(az containerapp show \
  --name ca-hw-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --query 'properties.configuration.ingress.fqdn' -o tsv)

# Test health check
curl -I https://$FQDN/healthz

# Test the app
curl https://$FQDN/
```

## CI/CD Pipeline

The workflow triggers on pushes to `main` with changes to Terraform or the app code.

**Validation (automatic, runs on every push):**
1. Terraform format check
1. Format check (`terraform fmt -check -recursive`)
2. Terraform validate (bootstrap + workload)
3. Build container image
4. Scan image with Snyk (blocks on CRITICAL CVEs)

**Deployment (approval required):**
1. Build and push image to ACR
2. Scan with Snyk
3. Generate Terraform plan with cost estimate (Infracost)
4. **Wait for approval** (GitHub environment protection rule)
5. Run `terraform apply` to deploy Container App
6. Container App redeploys with new image

The approval gate ensures human review of cost impact and infrastructure changes before production apply. Infracost generates the cost estimate during the plan phase so the approval team can see the financial impact before proceeding.

## Observability & Monitoring

We instrument the platform for visibility: **logs**, **metrics**, **alerts**, and **costs**.

**Application Insights** - Distributed tracing and advanced monitoring with Application Performance Monitoring (APM):
- Collects traces, exceptions, and performance metrics
- Enables end-to-end request tracking
- Retention: 90 days
- Automatically correlates logs with metrics for root cause analysis

**Logs** - All Container App output flows to Log Analytics (30-day retention). Common queries:
```bash
# View recent logs
az monitor log-analytics query \
  --workspace-id <WORKSPACE_ID> \
  --analytics-query "ContainerAppConsoleLogs_CL | order by TimeGenerated desc | limit 50"

# Find errors
az monitor log-analytics query \
  --workspace-id <WORKSPACE_ID> \
  --analytics-query "ContainerAppConsoleLogs_CL | where Log_s contains '500' or Log_s contains 'ERROR'"

# Count requests by hour
az monitor log-analytics query \
  --workspace-id <WORKSPACE_ID> \
  --analytics-query "ContainerAppConsoleLogs_CL | summarize Count = count() by bin(TimeGenerated, 1h)"
```

**Metrics & Alerts** - Automated alerts monitor application health:
- **Restart count > 3 in 1 hour** (severity 1, critical): Indicates container crashes; requires investigation
- **Availability < 99%** (severity 1, critical): Application response rate degradation via Application Insights; immediate action needed

Scaling is driven by HTTP concurrent request load (100 requests/replica = scale threshold):
```bash
# View replica count and scaling config
az containerapp show \
  --name ca-hw-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --query "properties.template.scale"
```

**Receiving Alerts** - Alerts are configured to send email notifications to `<ALERT_EMAIL>` (configure via the `alert_email` Terraform variable). When the monitoring conditions are triggered, you'll receive alerts for:
- **Container App restarts** (> 3 in 1 hour)
- **Application availability drops** (< 99%)

The alerts are managed via Azure Monitor Action Group (`ag-hw-prod-uks-001`) and routed through the configured email receiver. The designated admin should have already received an email subscription confirmation from Azure Monitor; if not, have them check their spam folder or verify the email address in `terraform/workloads/helloworld/main.tf`.

To modify the alert email address, update the `alert_email` variable and re-apply Terraform.

**Costs** - Tracked pre-deployment via Infracost (cost impact in PR comments) and actual spending via Azure Cost Management:
```bash
# View daily spend
az costmanagement query \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --timeframe "MonthToDate" \
  --granularity "Daily" \
  --metrics "ActualCost"
```

**Production would add** - Custom dashboards, automated remediation (e.g., scale down and restart on repeated errors), and integration with incident management (PagerDuty, Opsgenie).

## Redundancy & Disaster Recovery

### Demo (Current State)
**High Availability:**
- Container App: 2-5 replicas with autoscaling (across a single availability zone in UK South)
- Terraform state: ZRS (Zone-Redundant Storage) — survives single datacenter failure in UK South
- Application Insights & Log Analytics: Replicated automatically by Azure (no manual setup)

**Limitations:**
- **Not zone-redundant**: Container App Environment doesn't have `zone_redundancy_enabled = true`. Failure in the single AZ = downtime
- **Single region** (UK South) — regional outage = full downtime
- ACR Basic tier: No geo-replication
- No automated backups for application code/images
- **RTO/RPO**: Would require manual redeploy from GitHub to another region (~30 mins)

**Recovery Steps If UK South Goes Down:**
1. `terraform init` pointing to same Storage Account (recovers state from ZRS replicas)
2. Modify region to another Azure region (e.g., `uks` → `weu`)
3. `terraform apply` to redeploy
4. Update DNS/Front Door to point to new region

### Production (Hardened Deployment)
**High Availability:**
- Container App: 2-5 replicas, **zone-redundant** across 3 AZs in primary region
- Terraform state: GRS or RA-GRS (Geo-Redundant Storage) — automatic failover to paired region
- ACR Premium: Geo-replication to secondary region (e.g., UK South + West Europe)
- Application Insights & Log Analytics: Replicate exports to Storage Account

**Disaster Recovery Strategy:**
Container Apps doesn't support native geo-replication, so DR requires **multi-region deployment**:

1. **Active-Active (High Cost, Zero Manual Intervention)**:
   - Identical Container App in secondary region, `zone_redundancy_enabled = true`
   - Azure Front Door Premium continuously routes traffic to both regions
   - ACR geo-replicated
   - Both regions serving traffic simultaneously
   - **On disaster**: Front Door health checks detect failure, automatically routes all traffic to healthy region
   - **NO manual intervention required** (fully automatic failover)
   - **RTO**: <5 seconds (Front Door health check and reroute)
   - **RPO**: <1 minute
   - **Cost**: ~$110/month additional (full duplicate infrastructure + Front Door)

2. **Active-Passive (Budget-Conscious, Manual Scale-Up)**:
   - Primary region: Running normally, zone-redundant
   - Secondary region: Infrastructure in Terraform, `min_replicas = 0` (costs nothing while idle)
   - On disaster: Operator runs `terraform apply` to secondary with `min_replicas = 2` to scale up
   - Front Door health checks detect failure, routes to secondary
   - **RTO**: 5-10 minutes (manual scale-up time)
   - **RPO**: 1-2 minutes
   - **Cost**: ~$20/month (standby infrastructure only)

3. **No Multi-Region DR (Cost-Optimized, Longest Recovery)**:
   - Zone redundancy within single region (protects against AZ failure)
   - Regional outage = manual redeploy to new region (~30 min)
   - **RTO**: 30 minutes
   - **RPO**: 15 minutes (from last commit in GitHub)
   - **Cost**: ~$11/month (zone redundancy surcharge only)

### Backup & Recovery Procedures

**Application Code & Images:**
```bash
# ACR geo-replication setup (production)
az acr replication create \
  --registry $ACR_NAME \
  --location westeurope

# Check replicas
az acr replication list --registry $ACR_NAME --output table
```

**Monitoring & Alerting:**
All Container App instances in both regions are monitored via Azure Monitor. Availability metrics and health probes alert operations immediately if either region becomes unhealthy. Front Door health checks (every 10 seconds) ensure traffic is routed only to healthy instances.

**Active-Passive Failover Task:**
If using active-passive DR, the failover procedure is:
```bash
# When primary region fails, manually scale secondary region:
az containerapp update \
  --name ca-hw-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --min-replicas 2  # Scale from 0 to active
```

## Troubleshooting

**Container app not responding:** Check logs via `az containerapp logs show`, verify replica count is > 0, review Application Insights for exceptions.

**High CPU/Memory under load:** Check if at max replicas (5) via `properties.template.scale`. If yes, increase `max_replicas` in Terraform.

**Unexpected cost spike:** Verify resource changes in `terraform plan` output (e.g., `max_replicas` increased), review Infracost cost estimates in PR comments.

**Terraform apply failed:** Most common causes are backend state lock timeout, insufficient OIDC federated credential permissions, or Azure resource quota limits. Check `terraform plan` output for detailed error.

## Cost Breakdown

| Resource | Monthly Cost |
|----------|--------------|
| Container Apps (2 replicas, 0.25 vCPU, 0.5 GiB each) | ~$24 |
| Container Registry (Basic) | ~$5 |
| Application Insights (90-day retention) | ~$2 |
| Log Analytics (30-day retention) | ~$1 |
| Storage Account (Terraform state) | ~$2 |
| **Total** | **~$34/month** |

**At peak load (5 replicas):** ~$55/month

We track this with Infracost, which estimates cost impact of every infrastructure change before it's deployed.

## Common Operations

**View logs:**
```bash
az containerapp logs show --name ca-hw-prod-uks-001 --resource-group rg-helloworld-prod-uks-001 --tail 100
```

**Test the app:**
```bash
FQDN=$(az containerapp show --name ca-hw-prod-uks-001 --resource-group rg-helloworld-prod-uks-001 --query 'properties.configuration.ingress.fqdn' -o tsv)
curl https://$FQDN/
```

**Check replica count & scaling:**
```bash
az containerapp show --name ca-hw-prod-uks-001 --resource-group rg-helloworld-prod-uks-001 --query "properties.template.scale"
```

## Contributing

This is a demo/learning project. The main branch is protected—changes go through PR, CI validation, and cost review.

To make changes:
1. Create a branch
2. Make your changes
3. Push and open a PR
4. GitHub Actions validates (terraform plan, Snyk scan, cost estimate)
5. Review the PR, merge to main
6. CD automatically deploys

