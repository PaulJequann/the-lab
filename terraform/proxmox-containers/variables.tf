variable "target_node" {
  type    = string
  default = "cedes"
}

variable "container_password" {
  type    = string
  default = ""
}

variable "container_image" {
  type = string
}

variable "pm_api_url" {
  default = "https://10.0.10.27:8006/api2/json"
}

# variable "pm_nodes" {
#   type        = list(string)
#   description = "List of nodes to deploy VMs to"
# }

variable "pm_user" {
  type    = string
  default = ""
}

variable "pm_password" {
  type    = string
  default = ""
}

variable "pm_api_token_id" {
  type    = string
  default = ""
}

variable "pm_api_token_secret" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "ciuser" {
  description = "value for the cloud-init user"
}

variable "cipassword" {
  description = "value for the cloud-init password"
}

# variable "template_name" {
#   type = string
# }

# variable "server_nodes" {
#   type = list(object({
#     target_node = string
#   }))
# }

variable "unifi_username" {
  description = "username for the unifi controller"
  type        = string
}

variable "unifi_password" {
  description = "password for the unifi controller"
  type        = string
}

variable "unifi_api_url" {
  description = "url for the unifi controller"
  type        = string
}