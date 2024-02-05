terraform {
  cloud {
    organization = "pauljequann"

    workspaces {
      name = "homelab-dev-server"
    }
  }
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc1"
    }
    unifi = {
      source  = "paultyng/unifi"
      version = "0.41.0"
    }
  }
}

provider "proxmox" {
  pm_parallel         = 1
  pm_tls_insecure     = true
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  # pm_password       = var.pm_password
  # pm_user           = var.pm_user
}
provider "unifi" {
  username       = var.unifi_username # optionally use UNIFI_USERNAME env var
  password       = var.unifi_password # optionally use UNIFI_PASSWORD env var
  api_url        = var.unifi_api_url  # optionally use UNIFI_API env var
  allow_insecure = true               # optionally use UNIFI_INSECURE env var
}