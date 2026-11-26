# Azure Hello World

A small, demo-able Azure Container Apps deployment managed with Terraform and
GitHub Actions. The application is intentionally reachable over HTTPS from the
public internet, while Azure management, registry, and state operations use
short-lived federated identity and Azure RBAC rather than stored credentials.

**Application:** This deployment wraps the official Docker Hub
[`library/hello-world`](https://hub.docker.com/_/hello-world) image in a
lightweight Python HTTP server. When you visit `/` over HTTPS, the server
executes the original hello-world binary, captures its output, and returns it
in an HTTP response. This design satisfies two constraints: using the exact
linked Docker image and providing a publicly accessible HTTP service endpoint.

## Design Decision: The Wrapper Pattern

The assignment specifies Docker Hub's `library/hello-world` image, which is a
static binary (from scratch) with no HTTP server—it prints to stdout and exits.
The assignment also requires the application to be "publicly accessible over the
internet," implying an HTTP endpoint. These are incompatible if treated literally.

**Three options were considered:**

1. **Job-only deployment**: Deploy the exact image as an Azure Container Apps Job.
   - ✅ Uses the unmodified Docker Hub image
   - ❌ Runs once and exits; no public HTTP endpoint. Would require reading logs.

2. **Dual deployment**: Deploy the exact image as a Job *and* a separate HTTP app.
   - ✅ Satisfies both literal requirements
   - ❌ Adds operational complexity; two separate applications.

3. **Wrapper pattern** (chosen):
   - Multi-stage build extracts `/hello` from the official image
   - Python HTTP server wraps it and executes on-demand
   - ✅ Single, cohesive deployment
   - ✅ Uses the official image (via multi-stage)
   - ✅ Provides public HTTP endpoint
   - ✅ Demonstrates understanding of container patterns

**Rationale**: In a real scenario, conflicting requirements would be clarified
with stakeholders. Here, the wrapper pattern was chosen because it delivers a
production-pattern solution (platform-managed HTTPS, clean stateless app) while
respecting the assignment's intent: use the hello-world image and expose it
publicly.

## Architecture

```text
Browser
   | HTTPS
   v
Azure Container Apps (external HTTPS ingress, 2+ replicas, request scaling)
   |
   +---> GET / --------+
   |                   |
   +---> GET /healthz  |
                       v
                  Python HTTP server
                       |
                       v
                  Executes /hello binary (from library/hello-world)
                       |
                       v
                   Captures stdout
                       |
                       v
                   Returns HTTP 200 with output

Container Apps managed identity (AcrPull)
   |
   v
Azure Container Registry (public endpoint, authenticated image pulls, admin disabled)

GitHub Actions -- OIDC --> scoped deployment identity
   |                         | Container Registry Tasks Contributor / AcrPush
   |                         | Contributor on workload resource group
   |                         | Blob Data Contributor on Terraform state account
   +-- build image ----------+--> ACR
   +-- Terraform apply ----------> workload resources
   +-- Terraform state ----------> Azure Blob (HTTPS, Entra ID/RBAC only)

Container Apps diagnostics --> Azure Monitor --> Log Analytics
```

Public network access here means the service endpoint is internet-routable; it
does not mean anonymous access to the registry or state. The app is the only
intentionally public application endpoint. ACR pulls require the app's managed
identity, and Terraform state requires Entra ID data-plane authorization.

## Repository layout

- `app/` contains the small Python HTTP service and a non-root container image.
  The wrapper executes the official `hello-world` binary on request and returns
  its output over HTTP.
- `terraform/bootstrap/` creates the state account, registry, workload resource
  group, managed identities, federated credential, and scoped role assignments.
  Bootstrap state is local because it creates the remote state account itself.
- `terraform/workloads/helloworld/` creates the Container Apps environment,
  app, diagnostics, and Log Analytics workspace using remote state.
- `.github/workflows/` validates pull requests and builds/deploys from `main`.

## What each file is for

| File | Purpose |
| --- | --- |
| `.gitignore` | Keeps Terraform state, local variables, plans, credentials, and provider caches out of Git. |
| `README.md` | Runbook, architecture, security boundaries, and production evolution. |
| `app/app.py` | Serves the hello-world page and `/healthz` probe. |
| `app/Dockerfile` | Packages the app into the non-root container image deployed to Azure. |
| `.github/workflows/ci-validate.yml` | Runs unprivileged formatting, Terraform validation, and image-build checks on pull requests. |
| `.github/workflows/cd-deploy.yml` | Uses protected-environment OIDC to build the image and apply the production Terraform plan. |
| `terraform/bootstrap/providers.tf` | Declares Terraform/provider versions, configures AzureRM, and reads the current operator identity. |
| `terraform/bootstrap/variables.tf` | Inputs for subscription, Azure region, repository, and GitHub environment. |
| `terraform/bootstrap/locals.tf` | Shared bootstrap resource names and tags. |
| `terraform/bootstrap/state.tf` | Creates the Terraform state account/container and grants the bootstrap operator Blob access. |
| `terraform/bootstrap/workload_foundation.tf` | Creates the workload resource group, ACR, managed identities, GitHub federation, and scoped role assignments. |
| `terraform/bootstrap/outputs.tf` | Values to copy into GitHub repository variables after bootstrap. |
| `terraform/bootstrap/.terraform.lock.hcl` | Pins the exact bootstrap provider versions and checksums for repeatable init. |
| `terraform/workloads/helloworld/providers.tf` | Declares the workload Terraform/provider versions, remote backend, and AzureRM provider. |
| `terraform/workloads/helloworld/variables.tf` | Workload inputs, including the registry and immutable build tag. |
| `terraform/workloads/helloworld/main.tf` | Creates the logging workspace, Container Apps environment, diagnostics, and public app. |
| `terraform/workloads/helloworld/outputs.tf` | Exposes the deployed HTTPS application URL. |
| `terraform/workloads/helloworld/.terraform.lock.hcl` | Pins the exact workload provider version and checksums independently of bootstrap. |

The two Terraform roots each keep their own provider lock file because they
initialize independently. Keep both lock files in Git. `.terraform/` folders,
state files, local `.tfvars`, and saved plans are generated/private working
files and are intentionally not repository deliverables.

## Quick Start

**New to this project?** See [QUICKSTART.md](QUICKSTART.md) for a step-by-step walkthrough of bootstrap, GitHub setup, and deployment.

---

## Prerequisites

- Terraform 1.6 or later and Azure CLI.
- An Azure subscription with permission to create resource groups, resources,
  and role assignments. Bootstrap requires Owner or equivalent permissions.
- A GitHub repository and permission to configure its variables and
  environments.

Azure resource creation and role assignment may incur charges. Review the
planned resources and pricing before applying, and destroy the demo when you
are finished.

## Architecture and Design

The following sections explain the architecture, design decisions, and security model. For step-by-step deployment instructions, see [QUICKSTART.md](QUICKSTART.md).

### Application Design


- The hello-world endpoint is intentionally unauthenticated and returns no
  user data. Do not extend it to handle sensitive operations without adding
  application authentication and authorization.
- Container Apps uses readiness/liveness probes, at least two replicas, and an
  HTTP-based scale rule. The managed environment uses Azure Monitor and sends
  diagnostic categories to Log Analytics.
- The registry has anonymous pull and its admin account disabled. The app pulls
  through a user-assigned managed identity with `AcrPull`.
- GitHub uses environment-scoped OIDC. Its deployment identity is limited to
  the workload resource group, the ACR build/push operations, and the state
  storage account. The identity itself is kept in the separate state resource
  group so its workload Contributor role cannot edit its own federation trust.
- Azure Blob state uses Entra ID authorization, HTTPS, TLS 1.2+, ZRS, versioning,
  and soft delete. Public blob/container access and storage account keys are
  disabled.
- Pull-request workflows perform no Azure login. Deployment requires a
  protected environment and should also be gated by repository branch
  protection.

The demo deliberately does not claim complete production isolation: the app,
ACR, and state endpoints are public-network reachable. The ACA environment is
not VNet-injected, so its replicas are not configured for zone redundancy.
It also omits a WAF to keep the interview demo focused and lower-cost. Those are
documented production changes below, rather than hidden behind unprovisioned
private networking.

## Production target: private network architecture

For production, retain the public HTTPS user experience but move the workload
and its dependencies behind a controlled network boundary:

```text
Internet
   |
Azure Front Door Premium / WAF (TLS, rate limits, threat rules)
   |
Private Link
   v
Internal Container Apps environment in workload VNet
   | private DNS
   +--> ACR private endpoint (managed identity, public access disabled)
   +--> Key Vault private endpoint (if the app needs secrets)
   +--> Storage private endpoint (state and application data)
   |
Private egress via Azure Firewall/NAT with explicit destinations

GitHub Actions OIDC
   |
Ephemeral self-hosted deployment runner in a dedicated subnet
   +--> private Azure endpoints and Azure control plane
```

The production implementation should:

1. Put the Container Apps environment in a delegated subnet, enable zone
   redundancy, and use internal ingress. Publish only through Front Door Premium
   with WAF policies, origin restrictions, rate limiting, and DDoS protection.
2. Disable public network access on ACR, Key Vault, and Storage; use private
   endpoints, private DNS zones, and centrally managed VNet connectivity.
3. Run deployment jobs on short-lived, isolated self-hosted runners with
   outbound egress restrictions. Keep pull-request validation unprivileged and
   separate from production deployment credentials.
4. Preserve OIDC and least privilege; use distinct plan and deployment
   identities, tightly scoped state access, protected environments, approvals,
   and short-lived runner lifetimes.
5. Add image vulnerability scanning, SBOM generation, signing and digest-based
   deployment; pin base images by digest and automate reviewed updates for the
   pinned GitHub Actions.
6. Add Azure Policy/Defender for Cloud, centralized diagnostic retention,
   actionable availability/security alerts, tested backup/restore, and a
   documented regional disaster-recovery strategy.

Private endpoints alone are not sufficient: the runner, DNS, routes, egress,
and operator access must also be designed. In particular, GitHub-hosted runners
cannot reach private endpoints without an established private connectivity
path. That is why the private runner is a production architecture decision,
not a prerequisite for this public demo.

## Cleanup

Destroy the workload first while its remote state is available:

```shell
az login
az account set --subscription "<subscription-id>"

terraform -chdir=terraform/workloads/helloworld init -reconfigure \
  -backend-config="resource_group_name=rg-tfstate-prod-uks-001" \
  -backend-config="storage_account_name=<state-storage-account>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=helloworld-prod.tfstate" \
  -backend-config="use_azuread_auth=true"

terraform -chdir=terraform/workloads/helloworld destroy \
  -var="subscription_id=<subscription-id>" \
  -var="container_registry_name=<acr-name>" \
  -var="image_tag=<deployed-image-tag>"
```

Then destroy the bootstrap resources using its local state:

```shell
terraform -chdir=terraform/bootstrap destroy \
  -var="subscription_id=<subscription-id>" \
  -var="github_repository=<owner/repository>"
```

Deleting the bootstrap also deletes the remote state account. Confirm that no
other state or workloads depend on it before doing so.
