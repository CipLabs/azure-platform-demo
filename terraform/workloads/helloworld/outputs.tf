output "app_url" {
  description = "HTTPS URL of the public hello-world application."
  value       = "https://${azurerm_container_app.helloworld_app.latest_revision_fqdn}"
}

output "application_insights_id" {
  description = "ID of the Application Insights resource for the hello-world application."
  value       = azurerm_application_insights.helloworld_insights.id
}

output "application_insights_instrumentation_key" {
  description = "Instrumentation key for Application Insights (required for SDK configuration)."
  value       = azurerm_application_insights.helloworld_insights.instrumentation_key
  sensitive   = true
}

output "application_insights_connection_string" {
  description = "Connection string for Application Insights."
  value       = azurerm_application_insights.helloworld_insights.connection_string
  sensitive   = true
}

output "action_group_id" {
  description = "ID of the monitor action group for receiving alert notifications."
  value       = azurerm_monitor_action_group.helloworld_alerts.id
}
