provider "aws" {
  region = "ca-central-1"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "subnet_az" {
  default = ["ca-central-1a", "ca-central-1b"]
}

variable "public_subnet_cidrs" {
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_web_subnet_cidrs" {
  default = ["10.0.32.0/24", "10.0.33.0/24"]
}

# Create a VPC
resource "aws_vpc" "parmar_vpc" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "parmar_vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "parmar_igw" {
  vpc_id = aws_vpc.parmar_vpc.id
  tags = {
    Name = "parmar_igw"
  }
}

# Public Subnet
resource "aws_subnet" "parmar_pub_subnet" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.parmar_vpc.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.subnet_az[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "parmar_pub_subnet${count.index}"
  }
}

# Public Route Table
resource "aws_route_table" "parmar_pub_rt" {
  vpc_id = aws_vpc.parmar_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.parmar_igw.id
  }
  tags = {
    Name = "parmar_pub_rt"
  }
}

# Public Route Table association
resource "aws_route_table_association" "public_rt_assoc" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.parmar_pub_subnet[count.index].id
  route_table_id = aws_route_table.parmar_pub_rt.id
}

# Allocate an Elastic IP
resource "aws_eip" "parmar_nat_eip" {
  tags = {
    Name = "parmar_nat_eip"
  }
}

# Create NAT Gateway
resource "aws_nat_gateway" "parmar_nat" {
  allocation_id = aws_eip.parmar_nat_eip.id
  subnet_id     = aws_subnet.parmar_pub_subnet[1].id
  tags = {
    Name = "parmar_nat"
  }
  depends_on = [aws_internet_gateway.parmar_igw]
}

# Private Subnet
resource "aws_subnet" "parmar_priv_subnet" {
  count             = length(var.private_web_subnet_cidrs)
  vpc_id            = aws_vpc.parmar_vpc.id
  cidr_block        = var.private_web_subnet_cidrs[count.index]
  availability_zone = var.subnet_az[count.index]
  tags = {
    Name = "parmar_priv_subnet${count.index}"
  }
}

# Private Route Table
resource "aws_route_table" "parmar_priv_rt" {
  vpc_id = aws_vpc.parmar_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.parmar_nat.id
  }
  tags = {
    Name = "parmar_priv_rt"
  }
  depends_on = [aws_nat_gateway.parmar_nat]
}

# Private Route Table association
resource "aws_route_table_association" "private_rt_assoc" {
  count          = 2
  subnet_id      = aws_subnet.parmar_priv_subnet[count.index].id
  route_table_id = aws_route_table.parmar_priv_rt.id
}

# Security Group for application load balancer
resource "aws_security_group" "parmar_alb_sg" {
  name        = "parmar_alb_sg"
  description = "ALB Security Group"
  vpc_id      = aws_vpc.parmar_vpc.id
  tags = {
    Name = "parmar_alb_sg"
  }
}

# Security Group allow http inbound rule
resource "aws_vpc_security_group_ingress_rule" "external_alb_http" {
  security_group_id = aws_security_group.parmar_alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Security Group allow all traffic outbound rule
resource "aws_vpc_security_group_egress_rule" "external_alb_all_out" {
  security_group_id = aws_security_group.parmar_alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Security Group for frontend ECS
resource "aws_security_group" "parmar_ecs_sg" {
  name        = "parmar_ecs_sg"
  description = "ECS Tasks Security Group"
  vpc_id      = aws_vpc.parmar_vpc.id
  tags = {
    Name = "parmar_ecs_sg"
  }
}

# Security Group allow http inbound rule
resource "aws_vpc_security_group_ingress_rule" "frontend_ecs_from_alb" {
  security_group_id            = aws_security_group.parmar_ecs_sg.id
  referenced_security_group_id = aws_security_group.parmar_alb_sg.id
  from_port                    = 5000
  to_port                      = 5000
  ip_protocol                  = "tcp"
}

# Security Group allow all traffic outbound rule for frontend ECS
resource "aws_vpc_security_group_egress_rule" "frontend_ecs_all_out" {
  security_group_id = aws_security_group.parmar_ecs_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Application load balancer for frontend
resource "aws_lb" "parmar-alb" {
  name                       = "parmar-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.parmar_alb_sg.id]
  subnets                    = aws_subnet.parmar_priv_subnet[*].id
  enable_deletion_protection = false
  tags = {
    Name = "parmar-alb"
  }
}

resource "aws_key_pair" "mykeypair" {
  key_name   = "mykeypair"
  public_key = file("mykeypair.pub")
}

# Launch Template
resource "aws_launch_template" "parmar_lt" {
  name                   = "parmar_lt"
  image_id               = "ami-038aeeeeed95c7942"
  instance_type          = "t2.micro"
  vpc_security_group_ids = [aws_security_group.parmar_ecs_sg.id]
  key_name               = aws_key_pair.mykeypair.key_name
  depends_on             = [aws_key_pair.mykeypair, aws_security_group.parmar_ecs_sg]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "parmar_asg" {
  name             = "parmar_asg"
  desired_capacity = 2
  max_size         = 5
  min_size         = 1
  launch_template {
    id      = aws_launch_template.parmar_lt.id
    version = "$Latest"
  }
  vpc_zone_identifier = aws_subnet.parmar_priv_subnet[*].id
  tag {
    key                 = "Name"
    value               = "parmar_ec2"
    propagate_at_launch = true
  }
  depends_on = [aws_launch_template.parmar_lt]
}

resource "aws_autoscaling_policy" "avg_cpu_policy_greater" {
  name                   = "avg-cpu-policy-greater"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.parmar_asg.id
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 90.0
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.parmar_asg.id
  lb_target_group_arn    = aws_lb_target_group.parmar-lb-tg.arn
}

# Load balancer target group
resource "aws_lb_target_group" "parmar-lb-tg" {
  name        = "parmar-lb-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.parmar_vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "parmar-lb-tg"
  }
}

# Load balancer listner for frontend
resource "aws_lb_listener" "parmar_lb_listener" {
  load_balancer_arn = aws_lb.parmar-alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.parmar-lb-tg.arn
  }
}

# ECS Cluster for frontend
resource "aws_ecs_cluster" "parmar_ecs_cluster" {
  name = "parmar_ecs_cluster"
}

# ECS Task defination for frontend
resource "aws_ecs_task_definition" "parmar_ecs_task" {
  family                   = "parmar_ecs_task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  container_definitions = jsonencode([
    {
      name  = "parmar_ecs_task"
      image = "851725659285.dkr.ecr.ca-central-1.amazonaws.com/parmar-final:server-latest"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_frontend_logs.name
          "awslogs-region"        = "ca-central-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
      portMappings = [
        {
          containerPort = 5000
          hostPort      = 5000
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# ECS Service for frontend
resource "aws_ecs_service" "parmar_ecs" {
  name            = "parmar_ecs"
  cluster         = aws_ecs_cluster.parmar_ecs_cluster.id
  task_definition = aws_ecs_task_definition.parmar_ecs_task.arn
  launch_type     = "FARGATE"
  desired_count   = 2
  depends_on      = [aws_lb_listener.parmar_lb_listener]

  load_balancer {
    target_group_arn = aws_lb_target_group.parmar-lb-tg.arn
    container_name   = aws_ecs_task_definition.parmar_ecs_task.family
    container_port   = 5000
  }

  network_configuration {
    security_groups  = [aws_security_group.parmar_ecs_sg.id]
    subnets          = aws_subnet.parmar_priv_subnet[*].id
    assign_public_ip = false
  }

}

# IAM Roles
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

# IAM Policy
resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy_attachment" "ecs_cloudwatch_logs" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_cloudwatch_log_group" "ecs_frontend_logs" {
  name              = "/aws/ecs/parmar_ecs"
  retention_in_days = 14
}

output "alb_dns_name" {
  description = "Application load balancer dns name"
  value       = aws_lb.parmar-alb.dns_name
}
