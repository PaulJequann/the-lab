terraform {
  # cloud {
  #   organization = "pauljequann"

  #   workspaces {
  #     name = "homelab-glitchtip-data"
  #   }
  # }

  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.0"
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
}

provider "unifi" {
  username       = var.unifi_username
  password       = var.unifi_password
  api_url        = var.unifi_api_url
  allow_insecure = true
}
