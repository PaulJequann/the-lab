variable "node_name" {
  type = string
}

variable "target_node" {
  type = string
}

variable "pm_api_url" {
  default = "https://10.0.0.27:8006/api2/json"
}

variable "pm_user" {
  default = ""
}

variable "pm_password" {
  default = ""
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