resource "unifi_firewall_rule" "allow_inter_vlan_routing" {
  name = "Allow Inter-VLAN Routing"

  ruleset    = "LAN_IN"
  action     = "accept"
  rule_index = "2010"
  //TODO - Convert to tf instead of hard coded
  src_network_id = var.default_network_id
  dst_firewall_group_ids = [
    unifi_firewall_group.RFC1918.id
  ]
}

resource "unifi_firewall_rule" "allow_established_related" {
  name = "Allow Established, Related"

  ruleset           = "LAN_IN"
  action            = "accept"
  rule_index        = "2011"
  state_established = true
  state_related     = true
}

resource "unifi_firewall_rule" "block_inter_vlan_routing" {
  name = "Block Inter-VLAN Routing"

  ruleset    = "LAN_IN"
  action     = "drop"
  rule_index = "2100"
  //TODO - Convert to tf instead of hard coded
  src_firewall_group_ids = [
  unifi_firewall_group.RFC1918.id]
  dst_firewall_group_ids = [
    unifi_firewall_group.RFC1918.id
  ]
}

resource "unifi_firewall_rule" "block_to_secure_internal_gateways" {
  name = "Secure Internal Gateways"

  ruleset                = "LAN_IN"
  action                 = "drop"
  rule_index             = "2099"
  src_firewall_group_ids = [unifi_firewall_group.iot_and_stackseason.id]
  dst_firewall_group_ids = [
    unifi_firewall_group.secure_internal_gateways.id
  ]
}

resource "unifi_firewall_rule" "block_iot_to_udm_interface" {
  name = "Block IOT access to UDM interface"

  ruleset        = "LAN_LOCAL"
  action         = "drop"
  rule_index     = "2098"
  src_network_id = unifi_network.networks["iotings"].id
  dst_address    = cidrhost(unifi_network.networks["iotings"].subnet, 1)
  dst_firewall_group_ids = [
    unifi_firewall_group.http_https_ssh.id
  ]
}

resource "unifi_firewall_rule" "block_stackseason_to_udm_interface" {
  name = "Block StackSeason access to UDM interface"

  ruleset        = "LAN_LOCAL"
  action         = "drop"
  rule_index     = "2097"
  src_network_id = unifi_network.networks["stack-season"].id
  dst_address    = cidrhost(unifi_network.networks["stack-season"].subnet, 1)
  dst_firewall_group_ids = [
    unifi_firewall_group.http_https_ssh.id
  ]
}

resource "unifi_firewall_rule" "allow_lab_internal_to_all" {
  name = "Allow Lab Internal to All"

  ruleset        = "LAN_IN"
  action         = "accept"
  rule_index     = "2096"
  src_network_id = unifi_network.networks["lab-internal"].id
  dst_firewall_group_ids = [
    unifi_firewall_group.RFC1918.id
  ]
}

resource "unifi_firewall_rule" "allow_iot_stackseason_to_plex" {
  name = "Allow IoT, StackSeason to Plex"

  ruleset    = "LAN_IN"
  action     = "accept"
  rule_index = "2095"
  src_firewall_group_ids = [
    unifi_firewall_group.iot_and_stackseason.id
  ]
  dst_network_id = unifi_network.networks["lab-public"].id
  dst_firewall_group_ids = [
    unifi_firewall_group.plex.id
  ]
}

resource "unifi_firewall_rule" "allow_trusted_to_all" {
  name = "Allow Trusted to All"

  ruleset        = "LAN_IN"
  action         = "accept"
  rule_index     = "2094"
  src_network_id = unifi_network.networks["trusted"].id
  dst_firewall_group_ids = [
    unifi_firewall_group.RFC1918.id
  ]
}

resource "unifi_firewall_rule" "allow_to_iot" {
  name = "Allow to IoT"

  ruleset        = "LAN_IN"
  action         = "accept"
  rule_index     = "2093"
  dst_network_id = unifi_network.networks["iotings"].id
  src_firewall_group_ids = [
    unifi_firewall_group.labinternal_trusted_stackseason.id
  ]
}

