locals {
  container_app_environment_name = "cae-hw-prod-uks-001"
  container_app_name             = "ca-hw-prod-uks-001"
  log_analytics_workspace_name   = "log-hw-prod-uks-001"

  tags = {
    Environment = "Prod"
    Service     = "helloworld"
    ManagedBy   = "terraform"
  }
}

data "azurerm_resource_group" "helloworld_workload_rg" {
  name = var.resource_group_name
}

data "azurerm_container_registry" "helloworld_acr" {
  name                = var.container_registry_name
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
}

data "azurerm_user_assigned_identity" "helloworld_app_uaidentity" {
  name                = var.runtime_identity_name
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
}

resource "azurerm_log_analytics_workspace" "helloworld_logs" {
  name                       = local.log_analytics_workspace_name
  location                   = data.azurerm_resource_group.helloworld_workload_rg.location
  resource_group_name        = data.azurerm_resource_group.helloworld_workload_rg.name
  sku                        = "PerGB2018"
  retention_in_days          = 30
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_container_app_environment" "helloworld_cae" {
  name                  = local.container_app_environment_name
  location              = data.azurerm_resource_group.helloworld_workload_rg.location
  resource_group_name   = data.azurerm_resource_group.helloworld_workload_rg.name
  logs_destination      = "azure-monitor"
  public_network_access = "Enabled"
  tags                  = local.tags
}

data "azurerm_monitor_diagnostic_categories" "container_app_environment_diag" {
  resource_id = azurerm_container_app_environment.helloworld_cae.id
}

resource "azurerm_monitor_diagnostic_setting" "cae_diag" {
  name                       = "diag-helloworld-container-apps"
  target_resource_id         = azurerm_container_app_environment.helloworld_cae.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.helloworld_logs.id

  dynamic "enabled_log" {
    for_each = data.azurerm_monitor_diagnostic_categories.container_app_environment_diag.log_category_types
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = data.azurerm_monitor_diagnostic_categories.container_app_environment_diag.metrics
    content {
      category = enabled_metric.value
    }
  }
}

resource "azurerm_container_app" "helloworld_app" {
  name                         = local.container_app_name
  container_app_environment_id = azurerm_container_app_environment.helloworld_cae.id
  resource_group_name          = data.azurerm_resource_group.helloworld_workload_rg.name
  revision_mode                = "Single"
  max_inactive_revisions       = 3
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.helloworld_app_uaidentity.id]
  }

  registry {
    server   = data.azurerm_container_registry.helloworld_acr.login_server
    identity = data.azurerm_user_assigned_identity.helloworld_app_uaidentity.id
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 2
    max_replicas = 5

    http_scale_rule {
      name                = "http-concurrent-requests"
      concurrent_requests = "100"
    }

    container {
      name   = "helloworld"
      image  = "${data.azurerm_container_registry.helloworld_acr.login_server}/helloworld:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      liveness_probe {
        transport        = "HTTP"
        port             = 8080
        path             = "/healthz"
        interval_seconds = 10
        timeout          = 3
      }

      readiness_probe {
        transport        = "HTTP"
        port             = 8080
        path             = "/healthz"
        interval_seconds = 5
        timeout          = 3
      }
    }
  }
}

# Application Insights for distributed tracing and advanced monitoring
resource "azurerm_application_insights" "helloworld_insights" {
  name                = "ai-hw-prod-uks-001"
  location            = data.azurerm_resource_group.helloworld_workload_rg.location
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
  application_type    = "web"
  retention_in_days   = 90
  tags                = local.tags
}

# Action Group for alert notifications
resource "azurerm_monitor_action_group" "helloworld_alerts" {
  name                = "ag-hw-prod-uks-001"
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
  short_name          = "hw-alerts"
  tags                = local.tags

  email_receiver {
    name          = "admin-email"
    email_address = "chris.cipriano@outlook.com"
  }
}

# Alert: High restart count (>3 in 1 hour) - indicates container crashes
resource "azurerm_monitor_metric_alert" "restarts_high" {
  name                = "alert-restarts-high-hw-prod-uks"
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
  scopes              = [azurerm_container_app.helloworld_app.id]
  description         = "Alert when Container App restarts exceed 3 in 1 hour (indicates crashes)"
  severity            = 1
  enabled             = true
  frequency           = "PT5M"
  window_size         = "PT1H"

  criteria {
    metric_name      = "RestartCount"
    metric_namespace = "Microsoft.App/containerApps"
    operator         = "GreaterThan"
    threshold        = 3
    aggregation      = "Total"
  }

  action {
    action_group_id = azurerm_monitor_action_group.helloworld_alerts.id
  }

  tags = local.tags
}

# Alert: Availability (if response rate drops below 99%)
resource "azurerm_monitor_metric_alert" "availability_low" {
  name                = "alert-availability-low-hw-prod-uks"
  resource_group_name = data.azurerm_resource_group.helloworld_workload_rg.name
  scopes              = [azurerm_application_insights.helloworld_insights.id]
  description         = "Alert when application availability drops below 99%"
  severity            = 1
  enabled             = true
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_name      = "availabilityResults/availabilityPercentage"
    metric_namespace = "Microsoft.Insights/components"
    operator         = "LessThan"
    threshold        = 99
    aggregation      = "Average"
  }

  action {
    action_group_id = azurerm_monitor_action_group.helloworld_alerts.id
  }

  tags = local.tags
}
