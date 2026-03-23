output "glitchtip_data_mac_address" {
  value = proxmox_lxc.glitchtip_data.network[0].hwaddr
}

output "glitchtip_data_ip" {
  value = "10.0.10.83"
}
