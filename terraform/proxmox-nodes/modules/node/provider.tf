terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.0"
    }
  }
}

# provider "proxmox" {
# #   pm_parallel       = 1
#   pm_tls_insecure   = true
#   pm_api_url        = "https://10.0.0.27:8006/api2/json"
#   pm_password       = var.pm_password
#   pm_user           = var.pm_user
# }