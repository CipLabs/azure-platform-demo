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
- `rg-helloworld-prod-uks-001`: Application and runtime resources (updated frequently)

This separation reduces blast radius—if something goes wrong with the app, it doesn't touch the state storage. Different teams could own these independently.

### Why Infracost in CI/CD?
Infrastructure changes should show their cost impact before they're deployed. If someone accidentally changes `max_replicas` from 5 to 20, Infracost posts "$54/month cost increase" in the PR. Catch expensive mistakes early.

### Why Snyk for Image Scanning?
Container images inherit vulnerabilities from base images and dependencies. Snyk scans every image we build and blocks deployment if critical CVEs are found. It prevents shipping known-vulnerable code.

### Why This Specific Setup Is Not Production-Ready
- **No network isolation**: The app is publicly accessible. For regulated data, you'd need a VNet with private subnets.
- **No WAF**: Azure Front Door with WAF (~$500/month) would add DDoS protection and rate limiting. For a public demo with no data, it's overkill.
- **ACR is public**: For production, you'd use private endpoints so images never touch the public internet.

This is intentional. The demo shows the *patterns* (managed identity, automation, cost tracking) without over-engineering for a workload that handles no sensitive data.

## Terraform Structure: Bootstrap vs. Workload

We split Terraform into two layers: **bootstrap** and **workload**. Bootstrap creates the foundation (Terraform state storage, container registry, managed identities, CI/CD auth) that everything else depends on. Workload deploys the application on top of that foundation. This separation means bootstrap runs once and rarely changes, while workload can be deployed and updated frequently without touching shared infrastructure. It also reflects reality: on Day 0, you have no state storage yet, so you must store bootstrap state locally, migrate it to remote storage, then deploy workloads with remote state. This reduces the blast radius and separates concerns.

## How to Run It

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
  --name ca-helloworld-prod-uks-001 \
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

**Receiving Alerts** - Alerts are configured to send email notifications to `chris.cipriano@outlook.com`. When the monitoring conditions are triggered, you'll receive alerts for:
- **Container App restarts** (> 3 in 1 hour)
- **Application availability drops** (< 99%)

The alerts are managed via Azure Monitor Action Group (`ag-hw-prod-uks-001`) and routed through the configured email receiver. The designated admin should have already received an email subscription confirmation from Azure Monitor; if not, have them check their spam folder or verify the email address in `terraform/workloads/helloworld/main.tf`.

To modify the alert email address, update `email_address` in the action group configuration and re-apply Terraform.

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

## Troubleshooting

### Application Not Responding

**Symptom:** `curl https://$FQDN/` times out or returns 5xx errors

**Investigation steps:**
1. Check if container is running and healthy:
   ```bash
   az containerapp show \
     --name ca-helloworld-prod-uks-001 \
     --resource-group rg-helloworld-prod-uks-001 \
     --query "properties.runningStatus"
   ```

2. Check container logs for errors:
   ```bash
   az containerapp logs show \
     --name ca-helloworld-prod-uks-001 \
     --resource-group rg-helloworld-prod-uks-001 \
     --tail 100
   ```

3. Check if container is restarting repeatedly (crash loop):
   ```bash
   az containerapp revision list \
     --name ca-helloworld-prod-uks-001 \
     --resource-group rg-helloworld-prod-uks-001 \
     --output table
   ```
   Look for high restart counts in `Replicas` column.

4. Check Application Insights for detailed traces:
   ```bash
   # In Azure Portal: Application Insights → Failures
   # Look for exceptions or failed requests
   ```

### High CPU/Memory Usage

**Symptom:** Application is slow or timing out under load

**Investigation steps:**
1. Check current replica count and scaling status:
   ```bash
   az containerapp show \
     --name ca-helloworld-prod-uks-001 \
     --resource-group rg-helloworld-prod-uks-001 \
     --query "properties.template.scale"
   ```

2. Check if we're at max replicas (5):
   - If yes, the app is under sustained high load
   - Consider increasing `max_replicas` in Terraform

3. Check actual resource usage in Application Insights:
   ```bash
   # Portal: Application Insights → Performance
   ```

### Unexpected Cost Spike

**Symptom:** Infracost in PR shows unexpected cost increase

**Investigation steps:**
1. Check the Infracost output in the PR comment
2. Look for resource count changes (e.g., `max_replicas` increased accidentally)
3. Review the terraform plan diff
4. If correct, approve. If not, close the PR and fix the code.

**Actual cost spiking after deployment:**
```bash
# Check daily spend
az costmanagement query \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --timeframe "MonthToDate" \
  --granularity "Daily" \
  --metrics "ActualCost"
```

Likely causes:
- Container App scaled to max replicas (high request load)
- Application Insights data ingestion spike
- Storage account usage surge

### Terraform Apply Failed

**Symptom:** GitHub Actions deploy step fails with Terraform error

**Common causes & fixes:**

1. **Backend state lock timeout**
   - Another deployment is in progress
   - Wait for it to complete or manually unlock: `terraform force-unlock <LOCK_ID>`

2. **Insufficient permissions**
   - Verify OIDC federated credential is configured correctly
   - Check that managed identity has required roles (Contributor on subscription)

3. **Azure resource limits**
   - Container Apps quota exceeded
   - Contact Azure support to increase quota

4. **Metric alert metric names invalid**
   - Verify metric names exist in Azure Monitor for the resource type
   - Use `az monitor metrics list-definitions --resource <RESOURCE_ID>` to check available metrics

## Cost Breakdown

| Resource | Monthly Cost |
|----------|--------------|
| Container Apps (2 replicas baseline) | $64.80 |
| Container Registry (Premium) | $40 |
| Application Insights (90-day retention) | ~$2 |
| Log Analytics (Store logs for 30 days) | $1 |
| Storage Account | $5 |
| **Total** | **~$113/month** |

**At peak load (5 replicas):** ~$182/month

We track this with Infracost, which estimates cost impact of every infrastructure change before it's deployed. Application Insights is minimal cost (~$2/month) for a low-volume demo app but provides high-value distributed tracing and alerting.

## Scaling and Future Expansion

### Right Now (This Demo)
- 2-5 replicas (autoscales on HTTP request load)
- Single region (UK South)
- Public endpoint

### Next Phase (If We Add Data/Users)
1. **Custom domain**: Add your own domain + managed certificate
2. **Multi-region**: Replicate to another Azure region for HA
3. **Cost optimization**: Reserved instances (20-30% discount for predictable workloads), scheduled scale-down during off-hours
4. **Advanced observability**: Application Insights, automated alerting, custom dashboards

### Production Hardening (If We Handle Customer Data)
1. **Network isolation**: VNet with private subnets, private endpoints for ACR and storage
2. **DDoS/WAF**: Azure Front Door with Web Application Firewall (~$500/month)
3. **Access control**: NSGs on subnets to prevent lateral movement
4. **Image trust**: Container Registry content trust (cryptographic signing)
5. **Secrets management**: Key Vault for runtime secrets (API keys, etc.)
6. **Compliance scanning**: Policy enforcement, audit logging

## Useful Commands

### View Container App Logs
```bash
az containerapp logs show \
  --name ca-helloworld-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --tail 100
```

### Check Scaling Events
```bash
az containerapp revision list \
  --name ca-helloworld-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --output table
```

### View Infrastructure Costs (Actual)
```bash
az costmanagement query \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --timeframe "MonthToDate" \
  --granularity "Daily" \
  --metrics "ActualCost"
```

## Security Notes

**What's protected:**
- HTTPS only (TLS 1.2+)
- Managed identity auth (no password/key sprawl)
- Entra ID RBAC (fine-grained permissions)
- No secrets in GitHub (OIDC federated auth)
- Image vulnerability scanning (Snyk)
- Health checks (containers restart on failure)

**What's not (and why):**
- No WAF: Not needed for a stateless public demo with no data
- No private network: Everything is intentionally public
- No IP restrictions: Demo should be accessible
- ACR is public: Images are public containers anyway

This is appropriate for a demo. Production data would require the hardening mentioned above.

## Contributing

This is a demo/learning project. The main branch is protected—changes go through PR, CI validation, and cost review.

To make changes:
1. Create a branch
2. Make your changes
3. Push and open a PR
4. GitHub Actions validates (terraform plan, Snyk scan, cost estimate)
5. Review the PR, merge to main
6. CD automatically deploys

