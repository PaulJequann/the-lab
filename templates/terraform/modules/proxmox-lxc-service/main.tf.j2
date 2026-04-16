resource "proxmox_lxc" "this" {
  target_node = var.target_node

  hostname        = var.hostname
  ostemplate      = var.template_name
  password        = var.cipassword
  unprivileged    = true
  ssh_public_keys = file(var.ssh_key_file)
  onboot          = true
  start           = true

  cores  = var.cores
  memory = var.memory
  swap   = var.swap

  rootfs {
    storage = var.storage
    size    = var.disk_size
  }

  network {
    name   = "eth0"
    bridge = var.bridge
    gw     = var.gateway
    ip     = "${var.ip_address}/${var.cidr_suffix}"
  }

  nameserver = var.nameserver
}

resource "unifi_user" "this" {
  allow_existing         = true
  name                   = var.hostname
  mac                    = proxmox_lxc.this.network[0].hwaddr
  fixed_ip               = var.ip_address
  network_id             = var.unifi_network_id
  skip_forget_on_destroy = true
}
