# Quick Start Guide

This guide walks you through deploying the Azure hello-world application step by step.

## Phase 1: Local Setup (Bootstrap)

You run this **once locally** to create the Azure trust and state infrastructure.

**1. Prerequisites:**
```powershell
# Install these on your machine (Windows)
az login
terraform version  # must be >= 1.6
git clone https://github.com/YOUR_GITHUB_USERNAME/azure-platform-demo
cd azure-platform-demo
```

**2. Create bootstrap variables:**
```powershell
# Copy the example file
Copy-Item terraform\bootstrap\terraform.tfvars.example terraform\bootstrap\terraform.tfvars

# Edit it with YOUR values:
# - subscription_id: Your Azure subscription UUID (run: az account show --query id -o tsv)
# - github_repository: YOUR_USERNAME/azure-platform-demo
notepad terraform\bootstrap\terraform.tfvars  # or use Notepad++, VS Code, etc.
```

**3. Run bootstrap (creates trust + state storage in Azure):**
```powershell
az login
az account set --subscription "YOUR_SUBSCRIPTION_UUID"

terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

**4. Bootstrap will output several values. Write them down:**
```powershell
terraform -chdir=terraform/bootstrap output

# You need these six values for GitHub:
# - github_deployer_client_id
# - subscription_id
# - tenant_id
# - acr_name
# - tfstate_resource_group
# - terraform_state_storage_account
```

---

## Phase 2: GitHub Configuration (One-time setup)

You do this **once in GitHub** to tell GitHub Actions how to access Azure.

**1. Create GitHub environment:**
- Go to your repo → Settings → Environments
- Click "New environment"
- Name it: `production`
- Click "Create environment"

**2. Add repository variables:**
- Go to Settings → Secrets and variables → Actions
- Click "Variables" tab (NOT Secrets)
- Add these variables using the values from Step 1 above:

| Variable Name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `github_deployer_client_id` from bootstrap output |
| `AZURE_SUBSCRIPTION_ID` | `subscription_id` from bootstrap output |
| `AZURE_TENANT_ID` | `tenant_id` from bootstrap output |
| `ACR_NAME` | `acr_name` from bootstrap output |
| `TFSTATE_RESOURCE_GROUP` | `tfstate_resource_group` from bootstrap output |
| `TFSTATE_STORAGE_ACCOUNT` | `terraform_state_storage_account` from bootstrap output |

**That's it.** No secrets, no credentials, no tokens. Just these 6 variables.

---

## Phase 3: Deploy (Automated in GitHub Actions)

From here on, **you never run Terraform locally**. Everything runs in GitHub Actions.

**1. Create a pull request:**
```powershell
git checkout -b feature/initial-deploy
git add .
git commit -m "Initial Azure deployment"
git push origin feature/initial-deploy
```

Go to GitHub and open a pull request to `main`. The CI workflow will run:
- ✅ Terraform format check
- ✅ Terraform validate
- ✅ Docker image build (local only, doesn't push)

No Azure credentials needed for this—it's just checking code quality.

**2. Merge to main:**
Review the PR and merge to `main`. GitHub Actions will then:
1. Build the Docker image in your Azure Container Registry
2. Run `terraform init` with OIDC (federated identity—no stored credentials)
3. Create a Terraform plan
4. Apply the plan

**You can watch the deployment in real-time under Actions tab.**

**3. Get your app URL:**
Once deployment completes, go to Actions tab → Latest deployment run → Scroll down to "Terraform outputs".

Alternatively, if you want to read the state locally (optional), set up backend.conf:

```powershell
# Copy the example backend configuration
Copy-Item terraform\workloads\helloworld\backend.conf.example terraform\workloads\helloworld\backend.conf

# Edit it with values from bootstrap output
notepad terraform\workloads\helloworld\backend.conf
```

Then initialize and read the state:

```powershell
az login
az account set --subscription "YOUR_SUBSCRIPTION_UUID"

terraform -chdir=terraform\workloads\helloworld init

terraform -chdir=terraform\workloads\helloworld output app_url
```

Then visit that HTTPS URL in your browser. You should see "Hello from Docker!"

---

## Troubleshooting

**Q: Terraform fails with "Authorization failed"**
A: Azure role assignments can take 5-10 minutes to propagate. Wait and retry.

**Q: GitHub Actions workflow fails on first deployment**
A: Same as above—the federated credential was just created. Wait a few minutes and retry the deployment.

**Q: I want to destroy all resources**
```powershell
# Destroy workload first (don't destroy bootstrap state)
terraform -chdir=terraform/workloads/helloworld destroy

# Then destroy bootstrap (this deletes the state storage)
terraform -chdir=terraform/bootstrap destroy
```
