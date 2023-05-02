output "unifi_networks" {
  value = {
    for network in unifi_network.networks : network.name => {
      network_id = network.id
      purpose    = network.purpose
      subnet     = network.subnet
      vlan_id    = network.vlan_id
      dhcp_start = network.dhcp_start
      dhcp_stop  = network.dhcp_stop
    }
  }
}

# output "network_info" {
#   value = [for network_key, network in unifi_network : {
#     name          = network_key
#     purpose       = network.purpose
#     subnet        = network.subnet
#     vlan_id       = network.vlan_id
#     dhcp_start    = network.dhcp_start
#     dhcp_stop     = network.dhcp_stop
#     dhcp_enabled  = network.dhcp_enabled
#     multicast_dns = network.multicast_dns
#   }]
# }