output "portfolio_s3_bucket_name" {
  description = "Name of the S3 bucket used to store site data"
  value = aws_s3_bucket.portfolio.bucket
}