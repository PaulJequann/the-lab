variable "target_node" { type = string }
variable "hostname" { type = string }
variable "template_name" { type = string }
variable "ssh_key_file" { type = string }
variable "cipassword" { type = string }

variable "cores" { type = number }
variable "memory" { type = number }
variable "swap" { type = number }

variable "storage" { type = string }
variable "disk_size" { type = string }

variable "gateway" { type = string }
variable "bridge" { type = string }
variable "cidr_suffix" {
  type    = number
  default = 24
}
variable "ip_address" { type = string }
variable "nameserver" { type = string }

variable "unifi_network_id" { type = string }
