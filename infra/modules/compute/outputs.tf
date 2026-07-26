output "instance_id" {
  value = aws_instance.app.id
}

output "private_ip" {
  value = aws_instance.app.private_ip
}

output "public_ip" {
  value = aws_eip.app.public_ip
}

# EIP DNS is stable across stop/start; the instance's own public_dns is not
output "public_dns" {
  value = aws_eip.app.public_dns
}

output "instance_role_arn" {
  value = aws_iam_role.app.arn
}
