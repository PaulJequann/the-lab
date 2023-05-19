# Networking Hardware
resource "unifi_device" "ap_office" {
  name              = "AP - Office"
  mac               = "74:83:c2:77:fd:10"
  forget_on_destroy = false
}

resource "unifi_device" "ap_living_room" {
  name              = "AP - Living Room"
  mac               = "74:83:c2:7d:74:07"
  forget_on_destroy = false
}

resource "unifi_device" "switch_48_poe" {
  name              = "Switch - 48 POE"
  mac               = "e0:63:da:20:a9:ba"
  forget_on_destroy = false

  port_override {
    number          = 1
    port_profile_id = unifi_port_profile.lab_hardware.id
  }
  port_override {
    number          = 2
    port_profile_id = unifi_port_profile.lab_hardware.id
  }
  port_override {
    number          = 3
    port_profile_id = unifi_port_profile.lab_hardware.id
  }
  port_override {
    number          = 4
    port_profile_id = unifi_port_profile.lab_hardware.id
  }
  port_override {
    number          = 5
    port_profile_id = unifi_port_profile.lab_hardware.id
  }
}

# Compute Hardware
resource "unifi_user" "ap_office" {
  name                   = "AP - Office"
  mac                    = "74:83:C2:77:FD:10"
  network_id             = var.default_network_id
  skip_forget_on_destroy = true
}

resource "unifi_user" "ap_living_room" {
  name                   = "AP - Living Room"
  mac                    = "74:83:C2:7D:74:07"
  network_id             = var.default_network_id
  skip_forget_on_destroy = true
}

resource "unifi_user" "switch_48_poe" {
  name                   = "Switch - 48 POE"
  mac                    = "E0:63:DA:20:A9:BA"
  network_id             = var.default_network_id
  skip_forget_on_destroy = true
}

# Port Profiles

resource "unifi_port_profile" "lab_hardware" {
  name                   = "Lab Hardware"
  native_networkconf_id  = unifi_network.networks["lab-internal"].id
  tagged_networkconf_ids = [unifi_network.networks["lab-public"].id]
  poe_mode               = "off"
}

resource "unifi_port_profile" "cameras-security" {
  name                  = "cameras-security"
  native_networkconf_id = unifi_network.networks["security"].id
}

resource "unifi_port_profile" "trusted-devices" {
  name                  = "trusted-devices"
  native_networkconf_id = unifi_network.networks["trusted"].id
}