output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "backend_init_hint" {
  description = "How to point stacks at this bucket"
  value       = <<-EOT
    1. Copy infra/backends/*.hcl.example → *.hcl and set bucket = "${aws_s3_bucket.tfstate.id}"
    2. Global (after first local apply):
         cd infra/global && terraform init -backend-config=../backends/global.hcl -migrate-state
    3. Dev / prod:
         cd infra/environments/<env> && terraform init -backend-config=../../backends/<env>.hcl -migrate-state
    4. Pipeline uses the same bucket via -backend-config generated from AWS_ACCOUNT_ID
  EOT
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.id
}

output "zone_id" {
  value = var.domain_name != "" ? aws_route53_zone.main[0].zone_id : null
}

output "name_servers" {
  description = "Set these 4 values as custom nameservers at your registrar (Namecheap: Domain -> Nameservers -> Custom DNS)"
  value       = var.domain_name != "" ? aws_route53_zone.main[0].name_servers : null
}

output "guardduty_enabled" {
  value = var.enable_guardduty
}

output "github_actions_role_arn" {
  description = "GitHub Actions variable AWS_ROLE_ARN (Terraform plan/apply)"
  value       = var.enable_github_oidc ? aws_iam_role.github_terraform[0].arn : null
}

output "github_deploy_role_arn" {
  description = "GitHub Actions variable AWS_DEPLOY_ROLE_ARN (FE/BE ASG roll only)"
  value       = var.enable_github_oidc ? aws_iam_role.github_deploy[0].arn : null
}
