resource "proxmox_lxc" "glitchtip_data" {
  target_node = "mia"

  hostname        = "glitchtip-data"
  ostemplate      = var.template_name
  password        = var.cipassword
  unprivileged    = true
  ssh_public_keys = file(var.ssh_key_file)
  onboot          = true
  start           = true

  cores  = 2
  memory = 6144
  swap   = 0

  rootfs {
    storage = "local-lvm"
    size    = "40G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw     = "10.0.10.1"
    ip     = "10.0.10.83/24"
  }

  nameserver = "1.1.1.1"
}

resource "unifi_user" "glitchtip_data" {
  allow_existing         = true
  name                   = "glitchtip-data"
  mac                    = proxmox_lxc.glitchtip_data.network[0].hwaddr
  fixed_ip               = "10.0.10.83"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = true
}
