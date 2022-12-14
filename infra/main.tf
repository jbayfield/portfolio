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
  region = var.s3_region
}

# ACM certificates have to be issued in us-east-1 to work with CloudFront
provider "aws" {
  alias = "acm"
  region = "us-east-1"
}

# Create bucket
resource "aws_s3_bucket" "portfolio" {
  bucket_prefix = "portfolio-bucket-"
}

# Issue certificate
resource "aws_acm_certificate" "cert" {
  provider = aws.acm # use our us-east-1 alias

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "portfolio" {
  name = var.domain_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "cert_val" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
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
  zone_id         = aws_route53_zone.portfolio.zone_id
}

# Wait for cert issue
resource "aws_acm_certificate_validation" "cert" {
  provider = aws.acm # use our us-east-1 alias

  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_val : record.fqdn]
}

# Set up CloudFront distribution
locals {
  s3_origin_id = "portfolioOrigin"
}

resource "aws_cloudfront_origin_access_identity" "portfolio" {
  comment = "Portfolio OAI"
}

# We need to do some function hax to make directory indexes work so get that ready
resource "aws_cloudfront_function" "portfolio_index_function" {
  name    = "DirectoryIndexFunction"
  runtime = "cloudfront-js-1.0"
  publish = true
  code    = file("files/index_rewrite_function.js")
}

resource "aws_cloudfront_distribution" "portfolio" {
  origin {
    domain_name = aws_s3_bucket.portfolio.bucket_regional_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.portfolio.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

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
    acm_certificate_arn = aws_acm_certificate.cert.arn
    ssl_support_method = "sni-only"
  }
}

resource "aws_route53_record" "portfolio_alias" {
  zone_id = aws_route53_zone.portfolio.zone_id
  name    = var.domain_name
  type    = "A"
  
  alias {
    name = aws_cloudfront_distribution.portfolio.domain_name
    zone_id = aws_cloudfront_distribution.portfolio.hosted_zone_id
    evaluate_target_health = true
  }
}

# Set S3 bucket policies
data "aws_iam_policy_document" "portfolio" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.portfolio.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.portfolio.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "portfolio" {
  bucket = aws_s3_bucket.portfolio.id
  policy = data.aws_iam_policy_document.portfolio.json
}

resource "aws_s3_bucket_public_access_block" "portfolio" {
  bucket = aws_s3_bucket.portfolio.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}