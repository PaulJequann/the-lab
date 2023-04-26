# all private ips
resource "unifi_firewall_group" "RFC1918" {
  name = "RFC1918"
  type = "address-group"
  members = [
    "192.168.0.0/16",
    "172.16.0.0/12",
    "10.0.0.0/8"
  ]
}

resource "unifi_firewall_group" "secure_internal_gateways" {
  name = "Secure Internal Gateways"
  type = "address-group"
  members = [
    cidrhost(unifi_network.networks["lab-internal"].subnet, 1),
    cidrhost(unifi_network.networks["lab-public"].subnet, 1),
    cidrhost(unifi_network.networks["trusted"].subnet, 1),
    cidrhost(unifi_network.networks["security"].subnet, 1),
  ]
}

resource "unifi_firewall_group" "iot_and_stackseason" {
  name = "IoT and StackSeason"
  type = "address-group"
  members = [
    unifi_network.networks["iotings"].subnet,
    unifi_network.networks["stack-season"].subnet,
  ]
}

resource "unifi_firewall_group" "labinternal_trusted_stackseason" {
  name = "LabPublic, Trusted, StackSeason"
  type = "address-group"
  members = [
    unifi_network.networks["lab-public"].subnet,
    unifi_network.networks["trusted"].subnet,
    unifi_network.networks["stack-season"].subnet,
  ]
}

resource "unifi_firewall_group" "http_https_ssh" {
  name = "HTTP, HTTPS, SSH"
  type = "port-group"
  members = [
    "80",
    "443",
    "22"
  ]
}

resource "unifi_firewall_group" "plex" {
  name = "Plex Group"
  type = "port-group"
  members = [
    "32400"
  ]
}