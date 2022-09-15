terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket = "portfolio-jb-terraform-state"
    key = "portfolio_state"
    region = "eu-west-2"
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "eu-west-2"
}

# ACM certificates have to be issued in us-east-1 to work with CloudFront
provider "aws" {
  alias = "acm"
  region = "us-east-1"
}

# Create bucket
resource "aws_s3_bucket" "portfolio_bucket" {
  bucket_prefix = "portfolio-bucket-"
}

# Issue certificate
resource "aws_acm_certificate" "portfolio_cert" {
  provider = aws.acm # use our us-east-1 alias

  domain_name       = "joshua.bayfield.me"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "portfolio_zone" {
  name = "joshua.bayfield.me"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "portfolio_cert_record" {
  for_each = {
    for dvo in aws_acm_certificate.portfolio_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.portfolio_zone.zone_id
}

# Wait for cert issue
resource "aws_acm_certificate_validation" "portfolio_cert_val" {
  provider = aws.acm # use our us-east-1 alias

  certificate_arn         = aws_acm_certificate.portfolio_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.portfolio_cert_record : record.fqdn]
}

# Set up CloudFront distribution
locals {
  s3_origin_id = "portfolioOrigin"
}

resource "aws_cloudfront_origin_access_identity" "portfolio_distribution_oai" {
  comment = "Portfolio OAI"
}

# We need to do some function hax to make directory indexes work so get that ready
resource "aws_cloudfront_function" "portfolio_index_function" {
  name    = "DirectoryIndexFunction"
  runtime = "cloudfront-js-1.0"
  publish = true
  code    = file("index_rewrite_function.js")
}

resource "aws_cloudfront_distribution" "portfolio_distribution" {
  origin {
    domain_name = aws_s3_bucket.portfolio_bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.portfolio_distribution_oai.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["joshua.bayfield.me"]

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    # Associate the rewrite function we made earlier
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.portfolio_index_function.arn
    }

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "blacklist"
      locations        = ["RU", "BY"]
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.portfolio_cert.arn
    ssl_support_method = "sni-only"
  }
}

resource "aws_route53_record" "portfolio_alias" {
  zone_id = aws_route53_zone.portfolio_zone.zone_id
  name    = "joshua.bayfield.me"
  type    = "A"
  
  alias {
    name = aws_cloudfront_distribution.portfolio_distribution.domain_name
    zone_id = aws_cloudfront_distribution.portfolio_distribution.hosted_zone_id
    evaluate_target_health = true
  }
}

# Set S3 bucket policies
data "aws_iam_policy_document" "portfolio_bucket_policy_doc" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.portfolio_bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.portfolio_distribution_oai.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "portfolio_bucket_policy" {
  bucket = aws_s3_bucket.portfolio_bucket.id
  policy = data.aws_iam_policy_document.portfolio_bucket_policy_doc.json
}

resource "aws_s3_bucket_public_access_block" "portfolio_bucket_publicaccess" {
  bucket = aws_s3_bucket.portfolio_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Outputs for pipeline
output "portfolio_s3_bucket_name" {
  value = aws_s3_bucket.portfolio_bucket.bucket
}