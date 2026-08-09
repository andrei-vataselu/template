output "bucket_id" {
  value = aws_s3_bucket.logs.id
}

output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "bucket_domain_name" {
  value = aws_s3_bucket.logs.bucket_domain_name
}

output "alb_logs_prefix" {
  value = "alb"
}

output "cloudfront_logs_prefix" {
  value = "cloudfront"
}
