terraform {
  cloud {
    organization = "pauljequann"

    workspaces {
      name = "homelab-kubernetes-nodes"
    }
  }
  required_providers {
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

provider "unifi" {
  username       = ephemeral.infisical_secret.unifi_username.value
  password       = ephemeral.infisical_secret.unifi_password.value
  api_url        = var.api_url
  allow_insecure = true
}
