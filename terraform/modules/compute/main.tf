data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_role" {
  name               = "${var.environment}-ec2-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.environment}-ec2-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# EC2 #1: DR K3s & Redis Node
resource "aws_instance" "k3s_node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k3s_instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.k3s_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -e
    hostnamectl set-hostname ${var.environment}-k3s

    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey="${var.tailscale_auth_key}" --hostname="${var.environment}-k3s" --ssh

    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu

    iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 30080
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save
  EOT

  tags = {
    Name = "${var.environment}-k3s-node"
    Role = "DR-K3s-Redis"
  }
}

# EC2 #2: DR PostgreSQL Replica Node
resource "aws_instance" "db_node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.db_instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.db_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -e
    hostnamectl set-hostname ${var.environment}-db

    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey="${var.tailscale_auth_key}" --hostname="${var.environment}-db" --ssh

    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client
  EOT

  tags = {
    Name = "${var.environment}-db-node"
    Role = "DR-Postgres-Replica"
  }
}

# Elastic IP for DR K3s Node
resource "aws_eip" "k3s_eip" {
  instance = aws_instance.k3s_node.id
  domain   = "vpc"

  tags = {
    Name = "${var.environment}-k3s-eip"
  }
}
