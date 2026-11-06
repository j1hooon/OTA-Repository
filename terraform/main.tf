terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "HA-OTA-Platform"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# 공인 IP 동적 조회 + 응답 실패 및 비정상 포맷 방어(Postcondition)
data "http" "onprem_public_ip" {
  url = "https://checkip.amazonaws.com"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", chomp(self.response_body)))
      error_message = "Failed to fetch a valid IPv4 address from checkip.amazonaws.com."
    }
  }
}

locals {
  # 명시적으로 주입된 IP(TF_VAR_onprem_public_ip)가 있으면 우선 사용하고, 없을 때만 동적 조회 IP 사용
  effective_onprem_ip = coalesce(var.onprem_public_ip, chomp(data.http.onprem_public_ip.response_body))
}

# 1. VPC 모듈
module "vpc" {
  source             = "./modules/vpc"
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
}

# 2. S3 + CloudFront + Jenkins IAM 모듈
module "s3_cloudfront" {
  source      = "./modules/s3-cloudfront"
  environment = var.environment
}

# 3. DR Compute (EC2 #1: K3s+Redis, EC2 #2: Postgres Replica) 모듈
module "compute" {
  source                = "./modules/compute"
  environment           = var.environment
  public_subnet_id      = module.vpc.public_subnet_id
  k3s_security_group_id = module.vpc.k3s_security_group_id
  db_security_group_id  = module.vpc.db_security_group_id
  k3s_instance_type     = var.k3s_instance_type
  db_instance_type      = var.db_instance_type
  tailscale_auth_key    = var.tailscale_auth_key
}

# 4. Route 53 + CloudWatch Heartbeat Failover 모듈
module "dns_failover" {
  source           = "./modules/dns-failover"
  environment      = var.environment
  aws_region       = var.aws_region
  domain_name      = var.domain_name
  ota_subdomain    = var.ota_subdomain
  onprem_public_ip = local.effective_onprem_ip
  dr_k3s_public_ip = module.compute.k3s_public_ip
}
