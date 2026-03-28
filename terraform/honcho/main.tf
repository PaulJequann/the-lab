resource "proxmox_lxc" "honcho" {
  target_node = "mia"

  hostname        = "honcho"
  ostemplate      = var.template_name
  password        = var.cipassword
  unprivileged    = true
  ssh_public_keys = file(var.ssh_key_file)
  onboot          = true
  start           = true

  cores  = 4
  memory = 2048
  swap   = 0

  rootfs {
    storage = "local-lvm"
    size    = "50G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw     = "10.0.10.1"
    ip     = "10.0.10.84/24"
  }

  nameserver = "1.1.1.1"
}

resource "unifi_user" "honcho" {
  allow_existing         = true
  name                   = "honcho"
  mac                    = proxmox_lxc.honcho.network[0].hwaddr
  fixed_ip               = "10.0.10.84"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = true
}