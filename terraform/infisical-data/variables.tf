# Non-secret shape variables — defaults rendered from config.yaml.
# Secret variables (pm_api_token_id, pm_api_token_secret, cipassword,
# unifi_username, unifi_password) have no defaults and must be injected
# via TF_VAR_ env vars from scripts/load-bootstrap-secrets.sh.

variable "pm_api_url" {
  type    = string
  default = "https://10.0.10.27:8006/api2/json/"
}

variable "pm_api_token_id" {
  type      = string
  sensitive = true
}

variable "pm_api_token_secret" {
  type      = string
  sensitive = true
}

variable "ssh_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "template_name" {
  type    = string
  default = "vmstorage:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
}

variable "cipassword" {
  description = "Initial root password for the LXC guest"
  type        = string
  sensitive   = true
}

variable "unifi_username" {
  description = "username for the unifi controller"
  type        = string
}

variable "unifi_password" {
  description = "password for the unifi controller"
  type        = string
  sensitive   = true
}

variable "unifi_api_url" {
  description = "url for the unifi controller"
  type        = string
  default     = "https://10.0.0.1/"
}
