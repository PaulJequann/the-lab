data "terraform_remote_state" "unifi" {
  backend = "remote"

  config = {
    organization = "pauljequann"
    workspaces = {
      name = "homelab-unifi"
    }
  }
}

module "wendy-1" {
  source = "./modules/node"

  node_name     = "wendy-1"
  target_node   = "gpop"
  template_name = var.template_name

  ciuser       = var.ciuser
  cipassword   = var.cipassword
  ssh_key_file = var.ssh_key_file
}

module "wendy-2" {
  source = "./modules/node"

  node_name     = "wendy-2"
  target_node   = "jamahl"
  template_name = var.template_name

  ciuser       = var.ciuser
  cipassword   = var.cipassword
  ssh_key_file = var.ssh_key_file
}

module "wendy-3" {
  source = "./modules/node"

  node_name     = "wendy-3"
  target_node   = "cedes"
  template_name = var.template_name

  ciuser       = var.ciuser
  cipassword   = var.cipassword
  ssh_key_file = var.ssh_key_file
}

resource "unifi_user" "wendy-1" {
  name       = "Wendy-1"
  mac        = module.wendy-1.mac_address
  fixed_ip   = "10.0.10.80"
  network_id = "6445cb96b3a9fe1157bda058"
  # network_id             = data.terraform_remote_state.unifi.outputs.unifi_networks["lab-internal"].id
  skip_forget_on_destroy = false
}

resource "unifi_user" "wendy-2" {
  name       = "Wendy-2"
  mac        = module.wendy-2.mac_address
  fixed_ip   = "10.0.10.81"
  network_id = "6445cb96b3a9fe1157bda058"
  # network_id             = data.terraform_remote_state.unifi.outputs.unifi_networks["lab-internal"].id
  skip_forget_on_destroy = false
}

resource "unifi_user" "wendy-3" {
  name                   = "Wendy-3"
  mac                    = module.wendy-3.mac_address
  fixed_ip               = "10.0.10.82"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}