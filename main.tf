###############################
# Terraform + Provider
###############################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.39.0"
    }
  }

  required_version = ">= 1.0"
}

provider "aws" {
  region  = "us-east-1"
  profile = "default"
}

###############################
# Networking: VPC + Subnets
###############################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "it4200-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "it4200-igw"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "it4200-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "it4200-public-b"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "it4200-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

###############################
# Security Group
###############################
# Used by both ALB and ECS tasks
resource "aws_security_group" "ecs" {
  name        = "it4200-ecs-sg"
  description = "Allow HTTP and app traffic"
  vpc_id      = aws_vpc.main.id

  # ALB inbound from the internet on port 80
  ingress {
    description = "Allow HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ALB -> ECS tasks on port 8000 (app port)
  ingress {
    description = "Allow app port 8000 from internet/ALB"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "it4200-ecs-sg"
  }
}

###############################
# ALB + Target Group + Listener
###############################
resource "aws_lb" "alb" {
  name               = "class-api-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "it4200-alb"
  }
}

resource "aws_lb_target_group" "tg" {
  name        = "class-api-tg"
  port        = 8000            # must match containerPort
  protocol    = "HTTP"
  target_type = "ip"            # required for FARGATE
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "it4200-tg"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

###############################
# ECS Cluster
###############################
resource "aws_ecs_cluster" "cluster" {
  name = "it4200-cluster"

  tags = {
    Name = "it4200-cluster"
  }
}

###############################
# CloudWatch Log Group
###############################
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/class-api"
  retention_in_days = 1

  tags = {
    Name = "it4200-log-group"
  }
}

###############################
# ECS Task Definition
###############################
resource "aws_ecs_task_definition" "task" {
  family                   = "class-api-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  # Use pre-created LabRole from AWS Academy account
  execution_role_arn = "arn:aws:iam::979567835567:role/LabRole"
  task_role_arn      = "arn:aws:iam::979567835567:role/LabRole"

  container_definitions = jsonencode([
    {
      name  = "class-api"
      image = "bubbaj/class-api-it4200-2025-fall:20.9.0"

      portMappings = [{
        containerPort = 8000
        hostPort      = 8000
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/class-api"
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = "it4200-task-def"
  }
}

###############################
# ECS Service
###############################
resource "aws_ecs_service" "service" {
  name            = "class-api-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "class-api"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.listener,
    aws_cloudwatch_log_group.ecs
  ]

  tags = {
    Name = "it4200-service"
  }
}

###############################
# Output
###############################
output "alb_dns_name" {
  description = "DNS name of the application load balancer"
  value       = aws_lb.alb.dns_name
}
