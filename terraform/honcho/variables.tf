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

variable "pm_api_url" {
  type    = string
  default = "https://10.0.10.27:8006/api2/json/"
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
  description = "Cloud-init password (TF_VAR_cipassword, fed by load-bootstrap-secrets.sh terraform)"
  type        = string
  sensitive   = true
}

variable "unifi_api_url" {
  description = "url for the unifi controller"
  type        = string
  default     = "https://10.0.0.1/"
}
