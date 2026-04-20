terraform {
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
    unifi = {
      source  = "paultyng/unifi"
      version = "0.41.0"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.15"
    }
  }
}

provider "infisical" {
  host = "https://infisical.local.bysliek.com"
  auth = {
    universal = {
      client_id     = var.infisical_client_id
      client_secret = var.infisical_client_secret
    }
  }
}

# Proxmox API creds live at /ansible/proxmox/ (canonical); Terraform identity
# has cross-scope read granted by scripts/create-machine-identities.sh.
ephemeral "infisical_secret" "pm_api_token_id" {
  name         = "api_token_id"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/ansible/proxmox"
}

ephemeral "infisical_secret" "pm_api_token_secret" {
  name         = "api_token_secret"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/ansible/proxmox"
}

ephemeral "infisical_secret" "unifi_username" {
  name         = "username"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/terraform/unifi"
}

ephemeral "infisical_secret" "unifi_password" {
  name         = "password"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/terraform/unifi"
}

provider "proxmox" {
  pm_parallel         = 1
  pm_tls_insecure     = true
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = ephemeral.infisical_secret.pm_api_token_id.value
  pm_api_token_secret = ephemeral.infisical_secret.pm_api_token_secret.value
}

provider "unifi" {
  username       = ephemeral.infisical_secret.unifi_username.value
  password       = ephemeral.infisical_secret.unifi_password.value
  api_url        = var.unifi_api_url
  allow_insecure = true
}
