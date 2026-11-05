terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "OTA-Platform"
      Environment = "DR-Tokyo"
      ManagedBy   = "Terraform"
    }
  }
}

# VPC 모듈 호출
module "vpc" {
  source             = "./modules/vpc"
  environment        = "ota-dr-tokyo"
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
}

# S3 + CloudFront + Jenkins IAM 모듈 호출
module "s3_cloudfront" {
  source      = "./modules/s3-cloudfront"
  environment = "ota-dr-tokyo"
}
