output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_app_subnet_ids" {
  value = [aws_subnet.private_app_a.id, aws_subnet.private_app_b.id]
}

output "private_db_subnet_ids" {
  value = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}

output "nat_public_ip" {
  description = "NAT Gateway Elastic IP — allowlist this on Cognito WAF so app instances can call Cognito APIs"
  value       = aws_eip.nat.public_ip
}
