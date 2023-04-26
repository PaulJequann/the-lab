data "unifi_ap_group" "default" {
}

data "unifi_user_group" "default" {
}

resource "unifi_wlan" "iot" {
  name       = "IotNew"
  hide_ssid  = true
  passphrase = var.iot_wlan_passphrase
  security   = "wpapsk"

  # enable WPA2/WPA3 support
  wpa3_support      = true
  wpa3_transition   = true
  pmf_mode          = "optional"
  no2ghz_oui        = true
  network_id        = unifi_network.networks["iotings"].id
  ap_group_ids      = [data.unifi_ap_group.default.id]
  user_group_id     = data.unifi_user_group.default.id
  wlan_band         = "both"
  multicast_enhance = true
}