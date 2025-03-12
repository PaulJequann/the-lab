resource "unifi_user" "cedes" {
  name       = "cedes"
  mac        = "00:23:24:a2:50:d4"
  fixed_ip   = "10.0.10.26"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}
resource "unifi_user" "eyana" {
  name       = "eyana"
  mac        = "00:23:24:99:84:ac"
  fixed_ip   = "10.0.10.28"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}
resource "unifi_user" "jayden" {
  name       = "jayden"
  mac        = "00:23:24:a2:45:33"
  fixed_ip   = "10.0.10.25"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}
resource "unifi_user" "gpop" {
  name       = "gpop"
  mac        = "00:50:b6:1f:c7:3d"
  fixed_ip   = "10.0.10.29"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}
resource "unifi_user" "jamahl" {
  name       = "jamahl"
  mac        = "a0:ce:c8:8b:63:07"
  fixed_ip   = "10.0.10.24"
  network_id = "6445cb96b3a9fe1157bda058"
  skip_forget_on_destroy = false
}
