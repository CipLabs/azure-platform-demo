output "app_url" {
  description = "HTTPS URL of the public hello-world application."
  value       = "https://${azurerm_container_app.helloworld_app.latest_revision_fqdn}"
}
