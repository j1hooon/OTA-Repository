output "k3s_public_ip" {
  description = "Public IP of DR K3s Node (for Route 53 Failover Record)"
  value       = aws_eip.k3s_eip.public_ip
}

output "k3s_private_ip" {
  description = "VPC Private IP of DR K3s Node"
  value       = aws_instance.k3s_node.private_ip
}

output "db_private_ip" {
  description = "VPC Private IP of DR Postgres Replica Node (used by DR K3s pods)"
  value       = aws_instance.db_node.private_ip
}
