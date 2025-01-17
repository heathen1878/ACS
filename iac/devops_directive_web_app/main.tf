locals {
  # define some local variables
  resource_group_name            = format("rg-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  use_existing_network_watcher   = false
  network_watcher                = format("nw-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  virtual_network_name           = format("vnet-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  cae_infra_resource_group_name  = format("rg-cae-infra-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  postgresql_server_name         = format("psql-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  container_app_environment_name = format("cae-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  redis_container_app            = "ca-redis"
  api_container_app              = "ca-api"
  client_container_app           = "ca-client"
  nginx_container_app            = "ca-nginx"
  worker_container_app           = "ca-worker"
  api_docker_image               = format("index.docker.io/heathen1878/api:%s", var.docker_image_tag)
  client_docker_image            = format("index.docker.io/heathen1878/client:%s", var.docker_image_tag)
  nginx_docker_image             = "index.docker.io/heathen1878/nginx:latest"
  worker_docker_image            = format("index.docker.io/heathen1878/worker:%s", var.docker_image_tag)
  redis_cache                    = format("redis-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  postgresql                     = format("psql-%s-%s-%s-%s", local.name, var.environment, local.location_short_code, local.random)
  name                           = "fb"
  location                       = "uksouth"
  location_short_code            = "uks"
  random                         = random_id.this.hex
  tags = {
    managedby   = "Terraform"
    pipeline    = "Github Actions"
    environment = var.environment
  }

  # values from the Docker build task
  docker_image_name   = format("%s/%s:%s", var.docker_username, var.docker_image_name, var.docker_image_tag)
  docker_registry_url = "https://index.docker.io"
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags = merge(local.tags,
    {
      service = "Container App Environment"
    }
  )
}

resource "azurerm_network_watcher" "this" {
  name                = local.network_watcher
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  tags = merge(local.tags,
    {
      service = "Container App Environment"
    }
  )
}

resource "azurerm_virtual_network" "this" {
  name                = local.virtual_network_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  address_space = [
    "192.168.0.0/16"
  ]
  tags = merge(local.tags,
    {
      service = "Networking"
    }
  )

  depends_on = [
    azurerm_network_watcher.this
  ]
}

resource "azurerm_subnet" "cae" {
  name                 = "cae"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes = [
    "192.168.0.0/21"
  ]

  delegation {
    name = "cae"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "pe" {
  name                 = "pe"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes = [
    "192.168.8.0/24"
  ]
}

resource "azurerm_subnet" "psql" {
  name                 = "psql"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes = [
    "192.168.9.0/24"
  ]
  service_endpoints = [
    "Microsoft.Storage"
  ]

  delegation {
    name = "psql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "redis" {
  name                 = "redis"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes = [
    "192.168.10.0/24"
  ]
}

resource "azurerm_private_dns_zone" "psql" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql" {
  name                  = "psql"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.psql.name
  virtual_network_id    = azurerm_virtual_network.this.id

  depends_on = [
    azurerm_subnet.psql
  ]
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = local.postgresql_server_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = local.location
  version                       = "12"
  delegated_subnet_id           = azurerm_subnet.psql.id
  private_dns_zone_id           = azurerm_private_dns_zone.psql.id
  public_network_access_enabled = false
  administrator_login           = var.psql_admin_username
  administrator_password        = var.psql_admin_password
  storage_mb                    = 32768
  storage_tier                  = "P4"
  sku_name                      = "B_Standard_B2s"

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.psql
  ]

  // This block is used to ignore changes to the zone and standby_availability_zone
  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

resource "azurerm_container_app_environment" "this" {
  name                               = local.container_app_environment_name
  location                           = local.location
  resource_group_name                = azurerm_resource_group.this.name
  infrastructure_resource_group_name = local.cae_infra_resource_group_name
  infrastructure_subnet_id           = azurerm_subnet.cae.id
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  workload_profile {
    name                  = "Dedicated"
    workload_profile_type = "D4"

    minimum_count = 3
    maximum_count = 3
  }
  tags = merge(local.tags,
    {
      service = "Container App Environment"
    }
  )
}

resource "azurerm_container_app" "redis" {
  name                         = local.redis_container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Dedicated"

  ingress {
    exposed_port = 6379
    target_port  = 6379
    transport    = "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1
    container {
      name   = "redis"
      image  = "redis:latest"
      cpu    = "1.0"
      memory = "2Gi"
    }
  }
}

resource "azurerm_container_app" "worker" {
  name                         = local.worker_container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      env {
        name  = "REDIS_HOST"
        value = local.redis_container_app
      }

      env {
        name  = "REDIS_PORT"
        value = "6379"
      }

      name   = "worker"
      image  = local.worker_docker_image
      cpu    = "1.0"
      memory = "2Gi"
    }
  }
  tags = merge(local.tags,
    {
      service = "Worker"
    }
  )
}

resource "azurerm_container_app" "api" {
  name                         = local.api_container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Dedicated"

  ingress {
    exposed_port = 5000
    target_port  = 5000
    transport    = "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1
    container {
      env {
        name  = "REDIS_HOST"
        value = local.redis_container_app
      }

      env {
        name  = "REDIS_PORT"
        value = "6379"
      }

      env {
        name  = "PGUSER"
        value = var.psql_admin_username
      }

      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.this.fqdn
      }

      env {
        name  = "PGDATABASE"
        value = "fibonacci"
      }

      env {
        name  = "PGPORT"
        value = "5432"
      }

      env {
        name  = "PGPASSWORD"
        value = var.psql_admin_password
      }

      name   = "api"
      image  = local.api_docker_image
      cpu    = "1.0"
      memory = "2Gi"
    }
  }
  tags = merge(local.tags,
    {
      service = "Api"
    }
  )
}

resource "azurerm_container_app" "client" {
  name                         = local.client_container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  ingress {
    exposed_port = 3000
    target_port  = 3000
    transport    = "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    max_replicas = 1
    min_replicas = 1
    container {
      name   = "client"
      image  = local.client_docker_image
      cpu    = "1.0"
      memory = "2Gi"
    }
  }
  tags = merge(local.tags,
    {
      service = "Client"
    }
  )
  depends_on = [
    azurerm_container_app.api,
    azurerm_container_app.worker
  ]
}

resource "azurerm_container_app" "nginx" {
  name                         = local.nginx_container_app
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Dedicated"

  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 80

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    container {
      name   = "nginx"
      image  = local.nginx_docker_image
      cpu    = "1.0"
      memory = "2Gi"
    }
  }
  tags = merge(local.tags,
    {
      service = "nginx"
    }
  )
  depends_on = [
    azurerm_container_app.api,
    azurerm_container_app.client,
    azurerm_container_app.worker
  ]
}