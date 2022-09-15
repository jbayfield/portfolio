variable "domain_name" {
  description = "Domain name of the portfolio site"
  type        = string
  default     = "joshua.bayfield.me"
}

variable "s3_region" {
  description = "S3 region to store site data"
  type        = string
  default     = "eu-west-2"
}
