variable "namespace" {
  type        = string
  description = "Namespace to provision"
  default     = "devops-challenge"
}

variable "memory_quota" {
  type        = string
  description = "Total memory quota for the namespace"
  default     = "512Mi"
}

variable "api_token" {
  type        = string
  description = "API token consumed by the app"
  default     = "sk-skybyte-prod-7f3c9a2b1e8d4a6c"
}
