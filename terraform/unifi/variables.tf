variable "infisical_client_id" {
  description = "Infisical universal auth client_id (TF_VAR_infisical_client_id)"
  type        = string
  sensitive   = true
}

variable "infisical_client_secret" {
  description = "Infisical universal auth client_secret (TF_VAR_infisical_client_secret)"
  type        = string
  sensitive   = true
}

variable "infisical_project_id" {
  description = "Infisical project UUID (workspace_id for ephemeral resources)"
  type        = string
  default     = "914ba6ac-d254-403c-9f38-d2e3adf702b8"
}

variable "iot_wlan_passphrase" {
  description = "IoT WLAN passphrase (TF_VAR_iot_wlan_passphrase, sourced from Infisical /terraform/unifi/iot_wlan_passphrase)"
  type        = string
  sensitive   = true
}

variable "api_url" {
  type    = string
  default = "https://10.0.0.1/"
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

variable "default_network_id" {
  type = string
}
