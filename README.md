# Azure Hello World - Platform Demo

A working deployment of a stateless app on Azure Container Apps with Terraform, CI/CD via GitHub Actions, and infrastructure-as-code practices. This demonstrates core patterns: managed identity authentication, automated deployment, cost tracking, and supply chain security.

## What's Here

A public-facing HTTP service (`/healthz` for liveness, `/` returns a simple response) deployed to Azure Container Apps with:
- Terraform infrastructure (bootstrap + workload layers)
- GitHub Actions CI/CD (build, scan, deploy)
- Cost visibility (Infracost in every change)
- Supply chain scanning (Snyk for image vulnerabilities)
- Managed identity auth (no keys stored anywhere)

## High-Level Architecture

```
Internet Users
    │ HTTPS
    ↓
Public Container App (2-5 replicas, autoscaling)
    ├─→ Container Registry (pulls images)
    ├─→ Log Analytics (monitoring)
    └─→ Managed Identity (Azure AD auth)
        
GitHub Actions CI/CD
    ├─→ Build & Push Image
    ├─→ Scan Image (Snyk)
    └─→ Deploy to App via Terraform
```

**See [docs/architecture-current-demo.png](docs/architecture-current-demo.png) for the detailed diagram.**

## Design Decisions

### Why Container Apps Instead of Kubernetes?
We have a stateless HTTP service with no special requirements. Kubernetes adds operational overhead (cluster management, node patches, complexity) that isn't justified here. Container Apps gives us 80% of the features with 20% of the complexity—autoscaling, managed updates, integrated monitoring.

### Why Managed Identity, Not Stored Keys?
Storing keys in GitHub (even encrypted) is a liability. Managed identity means Azure AD authenticates the app automatically—no credentials to rotate, revoke, or accidentally leak. OIDC for GitHub Actions follows the same principle: GitHub gets a time-limited token, not a long-lived secret.

### Why Split Resource Groups?
- `rg-tfstate-prod-uks-001`: Terraform state storage (long lifecycle, rarely changes)
- `rg-helloworld-prod-uks-001`: Application and runtime resources (updated frequently)

This separation reduces blast radius—if something goes wrong with the app, it doesn't touch the state storage. Different teams could own these independently.

### Why Infracost in CI/CD?
Infrastructure changes should show their cost impact before they're deployed. If someone accidentally changes `max_replicas` from 5 to 20, Infracost posts "$54/month cost increase" in the PR. Catch expensive mistakes early.

### Why Snyk for Image Scanning?
Container images inherit vulnerabilities from base images and dependencies. Snyk scans every image we build and blocks deployment if critical CVEs are found. It's free and prevents shipping known-vulnerable code.

### Application Design: Wrapping a From-Scratch Binary in HTTP

The assignment required deploying `library/hello-world`—a minimal from-scratch image with just a static binary (`/hello`) and no shell or runtime.

**Problem:** A from-scratch binary isn't accessible over HTTP. It needs a listening port and HTTP handler.

**Solution:** We built a Python HTTP wrapper that:
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

The Dockerfile uses a multi-stage build to keep the final image small—only the extracted binary and Python interpreter, nothing else.

### Why This Specific Setup Is Not Production-Ready
- **No network isolation**: The app is publicly accessible. For regulated data, you'd need a VNet with private subnets.
- **No WAF**: Azure Front Door with WAF (~$500/month) would add DDoS protection and rate limiting. For a public demo with no data, it's overkill.
- **ACR is public**: For production, you'd use private endpoints so images never touch the public internet.

This is intentional. The demo shows the *patterns* (managed identity, automation, cost tracking) without over-engineering for a workload that handles no sensitive data.

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

### 3. Deploy Bootstrap Infrastructure

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
- VNet (for future private subnet expansion)
- ACR (container registry)
- Log Analytics workspace
- Managed identity for the app

### 4. Configure Remote State

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

### 5. Deploy the Application Workload

```bash
cd terraform/workloads/helloworld

terraform init \
  -backend-config="resource_group_name=rg-tfstate-prod-uks-001" \
  -backend-config="storage_account_name=$(terraform output -raw tfstate_storage_account -chdir=../../bootstrap)" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=helloworld-prod.tfstate" \
  -backend-config="use_azuread_auth=true" \
  -backend-config="use_oidc=true"

terraform plan -var-file="envs/prod.tfvars" -out=tfplan
terraform apply tfplan
```

### 6. Test the Deployment

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

**Validation (PR):**
1. Terraform format check
2. Terraform validate (bootstrap + workload)
3. Build container image
4. Scan image with Snyk (blocks on CRITICAL CVEs)
5. Infracost cost estimate (posts on PR)
6. Plan Terraform changes

**Deployment (merge to main):**
1. Build and push image to ACR
2. Scan with Snyk
3. Show cost estimate
4. Apply Terraform changes
5. Container App redeploys with new image

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

Container Apps exposes raw metrics like `UsageNanoCores` and `WorkingSetBytes`, but percentage-based CPU/Memory alerts require knowledge of resource limits. For production, use Application Insights metrics (which we have) combined with autoscaling rules (already configured to scale on request load).

Scaling is driven by HTTP concurrent request load (100 requests/replica = scale threshold):
```bash
# View replica count and scaling config
az containerapp show \
  --name ca-hw-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --query "properties.template.scale"
```

**Receiving Alerts** - By default, alerts are configured but notifications are disabled (avoid approval prompts). To enable email alerts, uncomment the email receiver in `terraform/workloads/helloworld/main.tf` and provide your email:
```hcl
email_receiver {
  name          = "admin-email"
  email_address = "your-email@example.com"
}
```

Then apply:
```bash
terraform apply -var-file="envs/prod.tfvars"
```

You'll receive an email subscription confirmation from Azure Monitor.

**Costs** - Tracked pre-deployment via Infracost (cost impact in PR comments) and actual spending via Azure Cost Management:
```bash
# View daily spend
az costmanagement query \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --timeframe "MonthToDate" \
  --granularity "Daily" \
  --metrics "ActualCost"
```

**When something breaks** - Follow this workflow:
1. Check Application Insights for trace/exception data
2. Check logs for error messages
3. Check if container is restarting (Restart Count spike = crash)
4. Check resource utilization (CPU/memory throttling)
5. Check if we're scaled up due to load
6. Check if costs are spiking (unexpected scale-up)

**Production would add** - Custom dashboards, automated remediation (e.g., scale down and restart on repeated errors), and integration with incident management (PagerDuty, Opsgenie).

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
3. **Access control**: IP restrictions on Container App, NSGs on subnets
4. **Image trust**: Container Registry content trust (cryptographic signing)
5. **Secrets management**: Key Vault for runtime secrets (API keys, etc.)
6. **Compliance scanning**: Policy enforcement, audit logging

## Monitoring and Troubleshooting

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

