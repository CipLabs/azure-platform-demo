variable "subscription_id" {
  description = "Azure subscription for the demo resources."
  type        = string
}

variable "location" {
  description = "Azure region for the demo resources."
  type        = string
  default     = "uksouth"
}

variable "github_repository" {
  description = "GitHub repository in owner/name format."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/name format."
  }
}

variable "github_organization_id" {
  description = "GitHub organization/user numeric ID (from OIDC error subject claim)"
  type        = string
}

variable "github_repository_id" {
  description = "GitHub repository numeric ID (from OIDC error subject claim)"
  type        = string
}

variable "github_environment" {
  description = "Protected GitHub environment allowed to deploy to Azure."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.github_environment))
    error_message = "github_environment may contain letters, digits, periods, underscores, and hyphens."
  }
}
