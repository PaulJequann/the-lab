resource "unifi_user" "rocket-1" {
  name       = "Rocket-1"
  mac        = module.rocket-1.mac_address
  fixed_ip   = "10.0.10.30"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

resource "unifi_user" "rocket-2" {
  name                   = "Rocket-2"
  mac                    = module.rocket-2.mac_address
  fixed_ip               = "10.0.10.31"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

resource "unifi_user" "rocket-3" {
  name                   = "Rocket-3"
  mac                    = module.rocket-3.mac_address
  fixed_ip               = "10.0.10.32"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

resource "unifi_user" "kk-1" {
  name                   = "KK-1"
  mac                    = module.kk-1.mac_address
  fixed_ip               = "10.0.10.40"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

resource "unifi_user" "kk-2" {
  name                   = "KK-2"
  mac                    = module.kk-2.mac_address
  fixed_ip               = "10.0.10.41"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

resource "unifi_user" "kk-3" {
  name                   = "KK-3"
  mac                    = module.kk-3.mac_address
  fixed_ip               = "10.0.10.42"
  network_id             = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}

# resource "proxmox_vm_qemu" "control_plane" {
#   count       = length(var.server_nodes)
#   name        = "rocket-${count.index + 1}"
#   target_node = var.server_nodes[count.index].target_node

#   clone = var.template_name

#   os_type  = "cloud-init"
#   cores    = 2
#   sockets  = "1"
#   cpu      = "host"
#   memory   = 4098
#   scsihw   = "virtio-scsi-pci"
#   bootdisk = "scsi0"

#   disk {
#     size     = "20G"
#     type     = "scsi"
#     storage  = "local-lvm"
#     iothread = 1
#   }

#   network {
#     model  = "virtio"
#     bridge = "vmbr0"
#     # tag    = data.terraform_remote_state.network.outputs.unifi_networks["lab-"].vlan_id
#   }

#   # cloud-init settings
#   # adjust the ip and gateway addresses as needed
#   ciuser     = var.ciuser
#   cipassword = var.cipassword
#   ipconfig0 = "ip=dhcp"
#   # ipconfig0 = "ip=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 30 + count.index)}/24, gw=${cidrhost(data.terraform_remote_state.network.outputs.unifi_networks["lab-internal"].subnet, 1)}"
#   sshkeys = file("${var.ssh_key_file}")
# }

# resource "proxmox_vm_qemu" "worker_nodes" {
#   for_each    = toset(var.pm_nodes)
#   name        = "worker-${each.value}"
#   target_node = each.value

#   clone = var.template_name

#   os_type  = "cloud-init"
#   cores    = 2
#   sockets  = "1"
#   cpu      = "host"
#   memory   = 4098
#   scsihw   = "virtio-scsi-pci"
#   bootdisk = "scsi0"

#   disk {
#     size     = "20G"
#     type     = "scsi"
#     storage  = "local-lvm"
#     iothread = 1
#   }

#   network {
#     model  = "virtio"
#     bridge = "vmbr0"
#   }

#   # cloud-init settings
#   # adjust the ip and gateway addresses as needed
#   ciuser     = var.ciuser
#   cipassword = var.cipassword
#   ipconfig0  = "ip=dhcp"
#   sshkeys    = file("${var.ssh_key_file}")
# }