output "tfstate_resource_group" {
  description = "Resource group containing the Terraform state account."
  value       = azurerm_resource_group.terraform_state_rg.name
}

output "terraform_state_storage_account" {
  description = "Name of the Terraform state storage account."
  value       = azurerm_storage_account.tfstate_storage_sa.name
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.helloworld_acr.name
}

output "github_deployer_client_id" {
  description = "Client ID of the GitHub Actions deployer managed identity (id-ghactionsdeploy-prod-uks-001)."
  value       = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.client_id
}

output "subscription_id" {
  description = "Azure subscription ID configured for this deployment."
  value       = var.subscription_id
}

output "tenant_id" {
  description = "Azure tenant ID for the current bootstrap operator."
  value       = data.azurerm_client_config.deployment_context.tenant_id
}
