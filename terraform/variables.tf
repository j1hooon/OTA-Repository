variable "aws_region" {
  description = "AWS DR Region (Tokyo)"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "Environment prefix for all DR resources"
  type        = string
  default     = "ota-dr-tokyo"
}

variable "vpc_cidr" {
  description = "Tokyo DR VPC CIDR"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Tokyo DR Public Subnet CIDR"
  type        = string
  default     = "10.20.1.0/24"
}

variable "k3s_instance_type" {
  description = "EC2 Instance Type for DR K3s & Redis Node"
  type        = string
  default     = "t3.medium"
}

variable "db_instance_type" {
  description = "EC2 Instance Type for DR Postgres Replica Node"
  type        = string
  default     = "t3.small"
}

variable "tailscale_auth_key" {
  description = "Tailscale Reusable Auth Key for zero-inbound VPN join"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Route 53 Hosted Zone Domain"
  type        = string
  default     = "j1hoon.store"
}

variable "ota_subdomain" {
  description = "OTA API Subdomain"
  type        = string
  default     = "ota.j1hoon.store"
}

variable "onprem_public_ip" {
  description = "Explicit On-Premise Public IP override (if null, dynamically fetched with strict validation)"
  type        = string
  default     = null

  validation {
    condition     = var.onprem_public_ip == null || can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.onprem_public_ip))
    error_message = "onprem_public_ip must be a valid IPv4 address."
  }
}
