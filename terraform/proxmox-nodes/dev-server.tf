resource "proxmox_vm_qemu" "dev_server" {
  name        = "dev"
  target_node = "jamahl"


  clone = var.template_name

  os_type  = "cloud-init"
  cores    = 8
  sockets  = "1"
  cpu      = "host"
  memory   = 12288
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disk {
    size    = "128G"
    type    = "scsi"
    storage = "local-lvm"
    # iothread = 1
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
    # tag    = data.terraform_remote_state.network.outputs.unifi_networks["lab-"].vlan_id
  }

  # cloud-init settings
  # adjust the ip and gateway addresses as needed
  ciuser     = var.ciuser
  cipassword = var.cipassword
  ipconfig0  = "ip=dhcp"
  # ipconfig0 = "ip=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 30 + count.index)}/24, gw=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 1)}"
  sshkeys = file("${var.ssh_key_file}")
}