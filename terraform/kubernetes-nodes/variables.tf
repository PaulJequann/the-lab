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

variable "api_url" {
  type    = string
  default = "https://10.0.0.1/"
}
