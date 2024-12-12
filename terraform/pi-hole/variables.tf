variable "pm_api_url" {
  type = string
}

variable "pm_nodes" {
  type        = list(string)
  description = "List of nodes to deploy VMs to"
}

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

variable "ssh_key_file" {
  default = "~/.ssh/id_ed25519.pub"
}

variable "ciuser" {
  description = "value for the cloud-init user"
}

variable "cipassword" {
  description = "value for the cloud-init password"
}

variable "template_name" {
  type = string
}

variable "server_nodes" {
  type = list(object({
    target_node = string
  }))
}

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

variable "pi-hole-ip" {
  description = "ip address for the pi-hole server"
  type        = string
}