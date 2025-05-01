variable "istio_version" {
  description = "Version of Istio helm chart. See https://github.com/istio/istio/releases for available versions."
  type        = string
  default     = ""
}

variable "istio_autoscaling" {
  description = "Enable Horizontal Pod Autoscaler for Istio."
  type        = bool
  default     = true
}

variable "istio_ambient_enabled" {
  description = "Enable Istio Ambient mode, which deploys ztunnel as a DaemonSet."
  type        = bool
  default     = false
}

variable "istio_values" {
  description = "Additional helm values file to pass to Istio as 'valuesContent' at the HelmChart."
  type        = string
  default     = ""
}
