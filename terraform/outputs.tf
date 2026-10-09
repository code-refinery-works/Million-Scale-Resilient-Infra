output "cloudfront_domain" {
  description = "CloudFront distribution domain (user-facing endpoint)"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "alb_dns" {
  description = "ALB DNS name (internal, accessed via CloudFront)"
  value       = aws_lb.alb.dns_name
}

output "redis_primary_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "sqs_queue_url" {
  description = "SQS queue URL for application write requests"
  value       = aws_sqs_queue.main.url
}

output "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint for Lambda worker DB connections"
  value       = aws_db_proxy.main.endpoint
}

output "aurora_cluster_endpoint" {
  description = "Aurora writer endpoint (use RDS Proxy in production)"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader endpoint for read replicas"
  value       = aws_rds_cluster.aurora.reader_endpoint
}