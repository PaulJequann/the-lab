resource "unifi_user" "jayden" {
  name                   = "Jayden"
  mac                    = "00:23:24:a2:45:33"
  fixed_ip               = "10.0.10.25"
  network_id             = unifi_network.networks["lab-internal"].id
  skip_forget_on_destroy = true
}

resource "unifi_user" "cedes" {
  name                   = "Cedes"
  mac                    = "00:23:24:a2:50:d4"
  fixed_ip               = "10.0.10.26"
  network_id             = unifi_network.networks["lab-internal"].id
  skip_forget_on_destroy = true
}

# resource "unifi_user" "mia" {
#     name = "Mia"
#     mac = "22:5f:be:39:e0:d3"
#     fixed_ip = "10.0.10.27"
#     network_id = unifi_network.networks["lab-internal"].id
#     skip_forget_on_destroy = true 
# }

resource "unifi_user" "eyana" {
  name                   = "Eyana"
  mac                    = "00:23:24:99:84:ac"
  fixed_ip               = "10.0.10.28"
  network_id             = unifi_network.networks["lab-internal"].id
  skip_forget_on_destroy = true
}

resource "unifi_user" "gpop" {
  name                   = "Gpop"
  mac                    = "00:50:b6:1f:c7:3d"
  fixed_ip               = "10.0.10.29"
  network_id             = unifi_network.networks["lab-internal"].id
  skip_forget_on_destroy = true
}