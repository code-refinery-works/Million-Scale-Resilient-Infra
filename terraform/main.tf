terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {}
}

provider "aws" { region = var.region }

locals {
  name = var.project
  az   = ["${var.region}a", "${var.region}c"]
  tags = { Project = local.name, ManagedBy = "terraform" }
}

# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = local.tags
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = local.az[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-pub-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = local.az[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-priv-${count.index}" })
}

resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = local.tags
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.igw.id }
  tags   = local.tags
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.nat.id }
  tags   = local.tags
}
resource "aws_route_table_association" "pub" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "priv" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags   = local.tags
}
resource "aws_security_group" "app" {
  name   = "${local.name}-app"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 8080; to_port = 8080; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks     = ["0.0.0.0/0"] }
  tags   = local.tags
}
resource "aws_security_group" "data" {
  name   = "${local.name}-data"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 3306; to_port = 3306; protocol = "tcp"; security_groups = [aws_security_group.app.id] }
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; security_groups = [aws_security_group.app.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks     = ["0.0.0.0/0"] }
  tags   = local.tags
}

# ── WAF + CloudFront ──────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "main" {
  provider    = aws
  name        = "${local.name}-waf"
  scope       = "CLOUDFRONT"
  description = "Managed rules + rate limit"
  default_action { allow {} }
  rule {
    name     = "AWSManaged"
    priority = 1
    override_action { none {} }
    statement { managed_rule_group_statement { name = "AWSManagedRulesCommonRuleSet"; vendor_name = "AWS" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "AWSManaged"; sampled_requests_enabled = true }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    action { block {} }
    statement { rate_based_statement { limit = 5000; aggregate_key_type = "IP" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "RateLimit"; sampled_requests_enabled = true }
  }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${local.name}-waf"; sampled_requests_enabled = true }
  tags = local.tags
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  web_acl_id      = aws_wafv2_web_acl.main.arn
  origin {
    domain_name = aws_lb.alb.dns_name
    origin_id   = "alb"
    custom_header { name = "X-Origin-Verify"; value = var.origin_verify_token }
    custom_origin_config {
      http_port = 80; https_port = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE","GET","HEAD","OPTIONS","PATCH","POST","PUT"]
    cached_methods         = ["GET","HEAD"]
    forwarded_values { query_string = true; cookies { forward = "none" } }
    min_ttl = 0; default_ttl = 30; max_ttl = 300
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate { cloudfront_default_certificate = true }
  tags = local.tags
}

# ── ALB ──────────────────────────────────────────────────────────────────────
resource "aws_lb" "alb" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  tags               = local.tags
}
resource "aws_lb_target_group" "app" {
  name        = "${local.name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/health"; healthy_threshold = 2; interval = 15 }
  tags = local.tags
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.app.arn }
}

# ── ECS Fargate ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = local.name
  setting { name = "containerInsights"; value = "enabled" }
  tags = local.tags
}
resource "aws_iam_role" "task_exec" {
  name               = "${local.name}-exec"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
  tags = local.tags
}
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "ecs-tasks.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "task_sqs" {
  role   = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Action = ["sqs:SendMessage"]; Resource = aws_sqs_queue.main.arn }] })
}
resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name      = "app"
    image     = var.app_image
    portMappings = [{ containerPort = 8080 }]
    environment = [
      { name = "REDIS_HOST"; value = aws_elasticache_replication_group.redis.primary_endpoint_address },
      { name = "SQS_URL";    value = aws_sqs_queue.main.url }
    ]
    logConfiguration = { logDriver = "awslogs"; options = { "awslogs-group" = "/ecs/${local.name}"; "awslogs-region" = var.region; "awslogs-stream-prefix" = "app" } }
  }])
  tags = local.tags
}
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
  tags              = local.tags
}
resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 3
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }
  load_balancer { target_group_arn = aws_lb_target_group.app.arn; container_name = "app"; container_port = 8080 }
  tags = local.tags
}
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 50
  min_capacity       = 3
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name}-redis"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${local.name}-redis"
  description                = "Redis cluster for ${local.name}"
  node_type                  = "cache.r7g.large"
  num_cache_clusters         = 2
  engine_version             = "7.1"
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.data.id]
  tags                       = local.tags
}

# ── SQS ──────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}
resource "aws_sqs_queue" "main" {
  name                       = "${local.name}-queue"
  visibility_timeout_seconds = 180
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn; maxReceiveCount = 3 })
  tags = local.tags
}

# ── Aurora Serverless v2 + RDS Proxy ─────────────────────────────────────────
resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name}-aurora"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}
resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = local.name
  engine                  = "aurora-mysql"
  engine_version          = "8.0.mysql_aurora.3.04.0"
  engine_mode             = "provisioned"
  database_name           = replace(local.name, "-", "_")
  master_username         = "admin"
  manage_master_user_password = true
  storage_encrypted       = true
  db_subnet_group_name    = aws_db_subnet_group.aurora.name
  vpc_security_group_ids  = [aws_security_group.data.id]
  serverlessv2_scaling_configuration { min_capacity = 0.5; max_capacity = 128 }
  skip_final_snapshot     = false
  final_snapshot_identifier = "${local.name}-final"
  tags = local.tags
}
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name}-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  tags               = local.tags
}
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${local.name}-reader"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  tags               = local.tags
}
resource "aws_iam_role" "rds_proxy" {
  name               = "${local.name}-rds-proxy"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "rds.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "rds_proxy_secrets" {
  role   = aws_iam_role.rds_proxy.id
  policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Action = ["secretsmanager:GetSecretValue"]; Resource = aws_rds_cluster.aurora.master_user_secret[0].secret_arn }] })
}
resource "aws_db_proxy" "main" {
  name                   = "${local.name}-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = aws_subnet.private[*].id
  vpc_security_group_ids = [aws_security_group.data.id]
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "REQUIRED"
    secret_arn  = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
  }
  tags = local.tags
}
resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name
  connection_pool_config { max_connections_percent = 100; connection_borrow_timeout = 120 }
}
resource "aws_db_proxy_target" "main" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier  = aws_rds_cluster.aurora.id
}

# ── Lambda Worker (SQS Consumer) ─────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = jsonencode({ Version = "2012-10-17"; Statement = [{ Effect = "Allow"; Principal = { Service = "lambda.amazonaws.com" }; Action = "sts:AssumeRole" }] })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"]
  tags = local.tags
}
resource "aws_iam_role_policy" "lambda_sqs_rds" {
  role   = aws_iam_role.lambda.id
  policy = jsonencode({ Version = "2012-10-17"; Statement = [
    { Effect = "Allow"; Action = ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"]; Resource = aws_sqs_queue.main.arn },
    { Effect = "Allow"; Action = ["rds-db:connect"]; Resource = "*" }
  ]})
}
resource "aws_lambda_function" "worker" {
  function_name = "${local.name}-worker"
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  role          = aws_iam_role.lambda.arn
  filename      = "${path.module}/worker.zip"
  timeout       = 30
  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.app.id]
  }
  environment {
    variables = { DB_PROXY_ENDPOINT = aws_db_proxy.main.endpoint }
  }
  tags = local.tags
}
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.worker.arn
  batch_size                         = 10
  function_response_types            = ["ReportBatchItemFailures"]
}