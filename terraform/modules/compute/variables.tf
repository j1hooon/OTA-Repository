variable "environment" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "k3s_security_group_id" {
  type = string
}

variable "db_security_group_id" {
  type = string
}

variable "k3s_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "db_instance_type" {
  type    = string
  default = "t3.small"
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}
