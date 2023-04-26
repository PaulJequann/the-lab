terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "pauljequann"

    workspaces {
      prefix = "homelab-unifi"
    }
  }
  #   cloud {
  #     organization = "pauljequann"

  #     workspaces {
  #       name = "homelab-unifi"
  #     }
  #   }
  required_version = "~> 1.4.5"
  required_providers {
    unifi = {
      source  = "paultyng/unifi"
      version = "0.41.0"
    }
  }
}


