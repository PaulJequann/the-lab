output "mac_address" {
  value = proxmox_vm_qemu.cluster_node.network[0].macaddr
}