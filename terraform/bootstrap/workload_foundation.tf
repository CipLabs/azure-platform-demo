
resource "azurerm_resource_group" "helloworld_workload_rg" {
  name     = "rg-helloworld-prod-uks-001"
  location = var.location
  tags     = local.tags
}

resource "random_string" "acr_name_suffix" {
  length  = 3
  lower   = true
  upper   = false
  numeric = false
  special = false
}

resource "azurerm_container_registry" "helloworld_acr" {
  name                          = "acrhelloworld${random_string.acr_name_suffix.result}"
  resource_group_name           = azurerm_resource_group.helloworld_workload_rg.name
  location                      = azurerm_resource_group.helloworld_workload_rg.location
  sku                           = "Basic"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  role_assignment_mode          = "LegacyRegistryPermissions"
  tags                          = local.tags
}

resource "azurerm_user_assigned_identity" "helloworld_app_uaidentity" {
  name                = "id-helloworldapp-prod-uks-001"
  location            = azurerm_resource_group.helloworld_workload_rg.location
  resource_group_name = azurerm_resource_group.helloworld_workload_rg.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "github_actions_deployer_uaidentity" {
  name                = "id-ghactionsdeploy-prod-uks-001"
  location            = azurerm_resource_group.terraform_state_rg.location
  resource_group_name = azurerm_resource_group.terraform_state_rg.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github_production_deployment_fedcred" {
  name                = "fedcred-github-production-environment"
  resource_group_name = azurerm_resource_group.terraform_state_rg.name
  parent_id           = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository_owner}@${var.github_organization_id}/${var.github_repository_name}@${var.github_repository_id}:environment:${var.github_environment}"
}

resource "azurerm_role_assignment" "github_deployer_workload_contributor" {
  scope                = azurerm_resource_group.helloworld_workload_rg.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "github_deployer_tfstate_blob_data_contributor" {
  scope                = azurerm_storage_account.tfstate_storage_sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "github_deployer_acr_push" {
  scope                = azurerm_container_registry.helloworld_acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "github_deployer_acr_contributor" {
  scope                = azurerm_container_registry.helloworld_acr.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "github_deployer_acr_tasks_contributor" {
  scope                = azurerm_container_registry.helloworld_acr.id
  role_definition_name = "Container Registry Tasks Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions_deployer_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "helloworld_app_acr_pull" {
  scope                = azurerm_container_registry.helloworld_acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.helloworld_app_uaidentity.principal_id
  principal_type       = "ServicePrincipal"
}
