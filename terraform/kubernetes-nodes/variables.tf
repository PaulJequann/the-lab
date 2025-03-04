variable "username" {
  type    = string
  default = "terraform"
}

variable "password" {
  type      = string
  sensitive = true
}

variable "api_url" {
  type      = string
  sensitive = true
}

variable "networks" {
  type = map(object({
    name    = string
    purpose = string

    subnet                       = string
    vlan_id                      = number
    dhcp_start                   = string
    dhcp_stop                    = string
    dhcp_enabled                 = bool
    dhcp_dns                     = optional(list(string))
    multicast_dns                = bool
    domain_name                  = optional(string)
    internet_access_enabled      = bool
    intra_network_access_enabled = bool
  }))

  description = "List of networks to create"
}

variable "iot_wlan_passphrase" {
  type      = string
  sensitive = true
}

variable "default_network_id" {
  type = string
}