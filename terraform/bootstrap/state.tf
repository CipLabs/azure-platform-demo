resource "azurerm_resource_group" "terraform_state_rg" {
  name     = local.terraform_state_resource_group_name
  location = var.location
  tags     = local.tags
}

resource "random_string" "tfstate_storage_suffix" {
  length  = 3
  lower   = true
  upper   = false
  numeric = false
  special = false
}

resource "azurerm_storage_account" "tfstate_storage_sa" {
  name                            = "${local.terraform_state_storage_account_base}${random_string.tfstate_storage_suffix.result}"
  resource_group_name             = azurerm_resource_group.terraform_state_rg.name
  location                        = azurerm_resource_group.terraform_state_rg.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags                            = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_role_assignment" "bootstrap_operator_tfstate_blob_data_contributor" {
  scope                = azurerm_storage_account.tfstate_storage_sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.deployment_context.object_id
  principal_type       = "User"
}

resource "azurerm_storage_container" "tfstate_blob_container" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate_storage_sa.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.bootstrap_operator_tfstate_blob_data_contributor]
}
