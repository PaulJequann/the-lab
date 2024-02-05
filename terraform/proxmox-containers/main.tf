resource "proxmox_lxc" "tailscale" {
  target_node     = "cedes"
  hostname        = "tailscale"
  ostemplate      = var.container_image
  password        = var.container_password
  unprivileged    = true
  ssh_public_keys = var.ssh_public_key

  cores  = 1
  memory = 512
  swap   = 512
  start  = true

  rootfs {
    storage = "local"
    size    = "4G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
  }
}