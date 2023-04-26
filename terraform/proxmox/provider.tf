terraform {
  # backend "remote" {
  #   hostname = "app.terraform.io"
  #   organization = "pauljequann"

  #   workspaces {
  #     prefix = "homelab-proxmox"
  #   }
  # }
  cloud {
    organization = "pauljequann"

    workspaces {
      name = "homelab-proxmox"
    }
  }
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.0"
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