terraform {
  required_version = ">= 1.12.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    # bucket is supplied at init time: -backend-config="bucket=tf-state-<account-id>"
    # (the bucket is created by infra/aws-bootstrap, or reused from another project)
    key          = "risk-scoring-app/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true # S3 native locking, no DynamoDB table needed
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# --- Networking: reuse the account's default VPC, this is meant to be the
#     Terraform equivalent of what ECS "Express Mode" provisions for you ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Container registry ---
resource "aws_ecr_repository" "risk_api" {
  name                 = "risk-scoring-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Security groups ---
resource "aws_security_group" "alb" {
  name        = "risk-scoring-app-alb"
  description = "Public ALB in front of the ECS service"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere (fronted by CloudFront)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "service" {
  name        = "risk-scoring-app-service"
  description = "ECS Fargate tasks, reachable only from the ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port from the ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Load balancer ---
resource "aws_lb" "app" {
  name               = "risk-scoring-app"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app" {
  name        = "risk-scoring-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --- ECS cluster, roles, task definition, service ---
resource "aws_ecs_cluster" "app" {
  name = "risk-scoring-app"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Role ECS uses to pull the image from ECR and write logs
resource "aws_iam_role" "ecs_task_execution" {
  name               = "risk-scoring-app-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Role the RUNNING container assumes (equivalent of the App Runner instance role)
resource "aws_iam_role" "ecs_task" {
  name               = "risk-scoring-app-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
# attach least-privilege policies here if the app needs to call other AWS services

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/risk-scoring-app"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "app" {
  family                   = "risk-scoring-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "risk-scoring-app"
      image     = "${aws_ecr_repository.risk_api.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "ENVIRONMENT", value = var.environment }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "risk-scoring-app"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true # default VPC subnets are public; no NAT gateway needed to pull from ECR
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "risk-scoring-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}

# --- Frontend: S3 (private) behind CloudFront ---
resource "aws_s3_bucket" "frontend" {
  bucket        = "risk-scoring-app-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "risk-scoring-app-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront in front of both the frontend bucket and the ALB, so the whole
# app is served from a single HTTPS origin and the frontend can call the API
# with relative paths (no CORS, no mixed content).
resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "alb-backend"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB has no listener cert; CloudFront still serves HTTPS to viewers
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # managed: CachingOptimized
  }

  # Route API calls straight to the ALB, same origin as the frontend
  ordered_cache_behavior {
    path_pattern             = "/score*"
    target_origin_id         = "alb-backend"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # managed: CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # managed: AllViewer
  }

  ordered_cache_behavior {
    path_pattern             = "/healthz"
    target_origin_id         = "alb-backend"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/docs", "/openapi.json", "/redoc"]
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "alb-backend"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.app.arn
          }
        }
      }
    ]
  })
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.app.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.app.id
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.risk_api.repository_url
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}
