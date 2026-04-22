resource "proxmox_vm_qemu" "cluster_node" {
  name        = var.node_name
  target_node = var.target_node

  clone = var.template_name

  os_type  = "cloud-init"
  cores    = 2
  sockets  = "1"
  cpu      = "host"
  memory   = 4098
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disk {
    size    = "20G"
    type    = "scsi"
    storage = "local-lvm"
    # iothread = 1
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
    # tag    = <canonical UniFi network output once local cross-root wiring exists>
  }

  # cloud-init settings
  # adjust the ip and gateway addresses as needed
  ciuser     = var.ciuser
  cipassword = var.cipassword
  ipconfig0  = "ip=dhcp"
  # ipconfig0 = "ip=<derived lab-internal address>/<cidr>, gw=<derived lab-internal gateway>"
  sshkeys = file("${var.ssh_key_file}")
}
