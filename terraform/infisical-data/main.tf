
module "service_host" {
  source = "../modules/proxmox-lxc-service"

  target_node      = "mia"
  hostname         = "infisical-data"
  ip_address       = "10.0.10.85"
  gateway          = "10.0.10.1"
  storage          = "local-lvm"
  disk_size        = "20G"
  cores            = 2
  memory           = 1024
  swap             = 0
  nameserver       = "1.1.1.1"
  bridge           = "vmbr0"
  cidr_suffix      = 24
  template_name    = var.template_name
  ssh_key_file     = var.ssh_key_file
  cipassword       = var.cipassword
  unifi_network_id = "6445cb96b3a9fe1157bda058"
}
