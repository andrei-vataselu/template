output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "backend_block_to_paste" {
  description = "Uncomment the backend block in each env's versions.tf and use this bucket"
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.tfstate.id}"
      key          = "<env>/terraform.tfstate"   # dev/terraform.tfstate or prod/terraform.tfstate
      region       = "${var.aws_region}"
      encrypt      = true
      use_lockfile = true
    }
    Then run: terraform init -migrate-state
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
