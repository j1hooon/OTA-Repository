output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_id" { value = aws_subnet.public.id }
output "k3s_security_group_id" { value = aws_security_group.k3s.id }
output "db_security_group_id" { value = aws_security_group.db.id }
