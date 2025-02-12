resource "unifi_network" "networks" {
  for_each = var.networks
  name     = each.key
  purpose  = each.value.purpose

  subnet        = each.value.subnet
  vlan_id       = each.value.vlan_id
  dhcp_start    = each.value.dhcp_start
  dhcp_stop     = each.value.dhcp_stop
  dhcp_enabled  = each.value.dhcp_enabled
  dhcp_dns      = try(each.value.dhcp_dns, null)
  domain_name   = try(each.value.domain_name, null)
  multicast_dns = each.value.multicast_dns
  #  internet_access_enabled      = each.value.internet_access_enabled
  #  intra_network_access_enabled = each.value.intra_network_access_enabled
}

# resource "unifi_network" "lab-internal" {
#     name    = "lab-internal"
#     purpose = "corporate"

#     subnet                       = "10.0.10.0/24"
#     vlan_id                      = 10
#     dhcp_start                   = "10.0.10.100"
#     dhcp_stop                    = "10.0.10.200"
#     dhcp_enabled                 = true
#     multicast_dns                = true
# }

# resource "unifi_network" "lab-public" {
#     name    = "lab-public"
#     purpose = "corporate"

#     subnet                       = "10.0.20.0/24"
#     vlan_id                      = 20
#     dhcp_start                   = "10.0.20.100"
#     dhcp_stop                    = "10.0.20.200"
#     dhcp_enabled                 = true
#     multicast_dns                = false
# }

# resource "unifi_network" "iotings" {
#     name    = "iotings"
#     purpose = "corporate"

#     subnet                       = "10.0.30.0/23"
#     vlan_id                      = 30
#     dhcp_start                   = "10.0.30.100"
#     dhcp_stop                    = "10.0.30.200"
#     dhcp_enabled                 = true
#     multicast_dns                = true
# }

# resource "unifi_network" "trusted" {
#     name    = "trusted"
#     purpose = "corporate"

#     subnet                       = "10.0.40.0/24"
#     vlan_id                      = 40
#     dhcp_start                   = "10.0.40.100"
#     dhcp_stop                    = "10.0.40.200"
#     dhcp_enabled                 = true
#     multicast_dns                = true
# }

# resource "unifi_network" "security" {
#     name    = "security"
#     purpose = "corporate"

#     subnet                       = "10.0.50.0/24"
#     vlan_id                      = 50
#     dhcp_start                   = "10.0.50.100"
#     dhcp_stop                    = "10.0.50.200"
#     dhcp_enabled                 = true
#     multicast_dns                = false
#     internet_access_enabled      = true
# }

# resource "unifi_network" "stack_season" {
#     name    = "stack-season"
#     purpose = "corporate"

#     subnet                       = "10.0.60.0/24"
#     vlan_id                      = 60
#     dhcp_start                   = "10.0.60.100"
#     dhcp_stop                    = "10.0.60.200"
#     dhcp_enabled                 = true
#     multicast_dns                = true
# }