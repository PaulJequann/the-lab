## ostemplate must be manually downloaded to the proxmox server
## and the path to the file must be provided in the variable
## pveam update
## pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst

resource "proxmox_lxc" "pihole" {
  target_node = var.pm_nodes.2 # cedes

  hostname        = "pihole"
  cores           = 1
  memory          = 512
  swap            = 0
  onboot          = true
  ostemplate      = var.template_name
  ssh_public_keys = file("${var.ssh_key_file}")
  password        = var.cipassword

  rootfs {
    storage = "vmstorage"
    size    = "8G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw    = "10.0.10.1"
    ip     = var.pi-hole-ip
  }

  nameserver = "1.1.1.1"

}

resource "unifi_user" "pihole" {
  name       = "pihole"
  mac        = proxmox_lxc.pihole.network[0].hwaddr
  fixed_ip   = "10.0.10.101"
  network_id = "6445cb96b3a9fe1157bda058"
  # network_id             = data.terraform_remote_state.unifi.outputs.unifi_networks["lab-internal"].id
  skip_forget_on_destroy = false
}