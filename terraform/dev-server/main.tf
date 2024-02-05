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
  onboot  = true
  # agent   = 1

  disks {
    scsi {
      scsi0 {
        disk {
          emulatessd = true
          size       = 128
          storage    = "local-lvm"
        }
      } 
    }
  }

  # disk {
  #   size    = "128G"
  #   type    = "scsi"
  #   storage = "local-lvm"
  #   # iothread = 1
  # }

  network {
    model  = "virtio"
    bridge = "vmbr0"
    # tag    = data.terraform_remote_state.network.outputs.unifi_networks["lab-"].vlan_id
  }

  bootdisk = "scsi0"

  # cloud-init settings
  # adjust the ip and gateway addresses as needed
  cloudinit_cdrom_storage = "local-lvm"
  ciuser     = var.ciuser
  cipassword = var.cipassword
  ipconfig0  = "ip=dhcp"
  # ipconfig0 = "ip=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 30 + count.index)}/24, gw=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 1)}"
  sshkeys = file("${var.ssh_key_file}")
}

resource "unifi_user" "dev" {
  name       = "dev"
  mac        = proxmox_vm_qemu.dev_server.network[0].macaddr
  fixed_ip   = "10.0.10.99"
  network_id = "6445cb96b3a9fe1157bda058"
  # network_id             = data.terraform_remote_state.unifi.outputs.unifi_networks["lab-internal"].id
  skip_forget_on_destroy = false
}