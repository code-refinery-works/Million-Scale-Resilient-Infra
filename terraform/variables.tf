variable "project" {
  description = "Project name used as resource prefix"
  type        = string
  default     = "scalable-app"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "app_image" {
  description = "ECS container image URI (e.g. 123456789.dkr.ecr.ap-northeast-1.amazonaws.com/app:latest)"
  type        = string
}

variable "acm_cert_arn" {
  description = "ACM certificate ARN for ALB HTTPS listener"
  type        = string
}

variable "origin_verify_token" {
  description = "Secret header value to restrict ALB access to CloudFront only"
  type        = string
  sensitive   = true
}