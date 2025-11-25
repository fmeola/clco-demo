provider "azurerm" {
  features {}
}

# Resource Group

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}


# App Service Plan

resource "azurerm_service_plan" "appplan" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}


# Virtual Network + Subnets

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Subnet for Web App
resource "azurerm_subnet" "web_subnet" {
  name                 = "${var.prefix}-web-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "webapp-delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Subnet for Private Endpoint
resource "azurerm_subnet" "pe_subnet" {
  name                 = "${var.prefix}-pe-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}


# Cognitive Account

resource "azurerm_cognitive_account" "cog" {
  name                  = "${var.prefix}-cog"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "TextAnalytics"
  sku_name              = "S"
  custom_subdomain_name = "${var.prefix}cogservice"

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_user_assigned_identity" "webapp_identity" {
  name                = "${var.prefix}-mi"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}


# Private DNS Zone
resource "azurerm_private_dns_zone" "dns" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dnslink" {
  name                  = "${var.prefix}-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}


# Private Endpoint
resource "azurerm_private_endpoint" "pe" {
  name                = "${var.prefix}-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe_subnet.id

  private_service_connection {
    name                           = "${var.prefix}-pe-connection"
    private_connection_resource_id = azurerm_cognitive_account.cog.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${var.prefix}-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.dns.id]
  }
}


# Web App
resource "azurerm_linux_web_app" "webapp" {
  name                = "${var.prefix}-webapp"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.appplan.location
  service_plan_id     = azurerm_service_plan.appplan.id

  https_only = true

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.webapp_identity.id
    ]
  }

  virtual_network_subnet_id = azurerm_subnet.web_subnet.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
    vnet_route_all_enabled = true
  }

  app_settings = {
    "AZ_ENDPOINT" = "https://${azurerm_cognitive_account.cog.custom_subdomain_name}.cognitiveservices.azure.com/"
    "AZ_KEY"      = azurerm_cognitive_account.cog.primary_access_key
  }
}
