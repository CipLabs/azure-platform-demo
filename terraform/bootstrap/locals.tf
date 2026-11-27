locals {
  terraform_state_resource_group_name  = "rg-tfstate-prod-uks-001"
  terraform_state_storage_account_base = "sttfstateproduksv1" # sttfstate (resource-type + purpose) + prod + uks + version

  tags = {
    Environment = "Prod"
    Service     = "platform"
    ManagedBy   = "terraform"
  }
}
