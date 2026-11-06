variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "domain_name" {
  description = "Route 53 Hosted Zone Domain (e.g., j1hoon.store)"
  type        = string
}

variable "ota_subdomain" {
  description = "OTA Endpoint FQDN (e.g., ota.j1hoon.store)"
  type        = string
}

variable "onprem_public_ip" {
  description = "Dynamically fetched Primary On-Premise Public IP"
  type        = string
}

variable "dr_k3s_public_ip" {
  description = "Secondary DR Tokyo K3s Elastic IP"
  type        = string
}
