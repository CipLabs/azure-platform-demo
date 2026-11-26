variable "subscription_id" {
  description = "Azure subscription containing the workload resource group."
  type        = string
}

variable "location" {
  description = "Azure region for the workload resources."
  type        = string
  default     = "uksouth"
}

variable "resource_group_name" {
  description = "Resource group created by the bootstrap configuration."
  type        = string
  default     = "rg-helloworld-prod-uks-001"
}

variable "container_registry_name" {
  description = "Azure Container Registry created by the bootstrap configuration."
  type        = string
}

variable "runtime_identity_name" {
  description = "User-assigned identity authorized to pull the app image (id-helloworldapp-prod-uks-001)."
  type        = string
  default     = "id-helloworldapp-prod-uks-001"
}

variable "image_tag" {
  description = "Immutable container image tag to deploy."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid OCI image tag of up to 128 characters."
  }
}
