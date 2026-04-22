terraform {
  required_version = "~> 1.10"

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

