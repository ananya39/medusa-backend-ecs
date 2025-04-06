resource "aws_vpc" "medusa_vpc"{
  cidr_block  ="10.0.0.0/16"
}

# create public subnets
resource "aws_subnet" "public_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.medusa_vpc.id
  cidr_block              = element(["10.0.1.0/24", "10.0.2.0/24"], count.index)
  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  map_public_ip_on_launch = true
}


# Internet gateway
resource "aws_internet_gateway" "medusa_igw"{
vpc_id = aws_vpc.medusa_vpc.id
}
# Route Table to send traffic to Internet Gateway
resource "aws_route_table" "medusa_route_table" {
  vpc_id = aws_vpc.medusa_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.medusa_igw.id
  }
}

# Associate the route table with the public subnets
resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.medusa_route_table.id
}

# Security Group for ECS (Allows HTTP traffic on port 5000)
resource "aws_security_group" "medusa_sg"{
   vpc_id=aws_vpc.medusa_vpc.id   
   name="medusa_sg"

    ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow all IPs (public)
  }
 egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

#ecs cluster
resource "aws_ecs_cluster" "medusa_cluster" {
  name = "medusa-cluster"
}

# Create ECR Repository for Medusa Backend
resource "aws_ecr_repository" "medusa_repo" {
  name = "medusa-backend"
}
# IAM Role for ECS Task Execution (ECR + CloudWatch)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach Execution Role Policy
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Role for ECS Task (your app)
resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach same basic policy (can be customized later)
resource "aws_iam_role_policy_attachment" "ecs_task_policy" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
# ECS Task Definition for Medusa Backend
resource "aws_ecs_task_definition" "medusa_task" {
  family                   = "medusa-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "medusa-backend",
      image     = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/medusa-backend",
      cpu       = 512,
      memory    = 1024,
      essential = true,
      portMappings = [
        {
          containerPort = 9000,
          hostPort      = 9000
        }
      ]
    }
  ])
}



# 1. Security Group for ALB
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.medusa_vpc.id

  ingress {
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

# 2. Create Application Load Balancer
resource "aws_lb" "medusa_alb" {
  name               = "medusa-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public_subnet[*].id
}

# 3. Create Target Group for ECS
resource "aws_lb_target_group" "medusa_tg" {
  name     = "medusa-tg"
  port     = 9000
  protocol = "HTTP"
  vpc_id   = aws_vpc.medusa_vpc.id
  target_type = "ip" # Required for Fargate
    health_check {
    path                = "/store/products"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

}

# 4. Create Listener for ALB
resource "aws_lb_listener" "medusa_listener" {
  load_balancer_arn = aws_lb.medusa_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.medusa_tg.arn
  }
}

# 5. Attach ECS Service to Target Group
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.public_subnet[*].id
    security_groups = [aws_security_group.medusa_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_tg.arn
    container_name   = "medusa-backend"
    container_port   = 9000
  }

  depends_on = [aws_lb_listener.medusa_listener]
}
