terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "external" "current_ip" {
  program = ["bash", "-c", "curl -s 'https://api.ipify.org?format=json'"]
}

locals {
  traffic_dist_map = {
    old-100 = {
      old  = 100
      new = 0
    }
    old-80 = {
      old  = 80
      new = 20
    }
    split = {
      old  = 50
      new = 50
    }
    old-20 = {
      old  = 20
      new = 80
    }
    old-0 = {
      old  = 0
      new = 100
    }
  }
}

resource "aws_vpc" "canary_vpc" {
  cidr_block = "192.168.0.0/24"
  tags = {
    Name = "canary_vpc",
  }
}

resource "aws_internet_gateway" "canary_igw" {
  vpc_id = aws_vpc.canary_vpc.id
  tags = {
    Name = "canary_igw",
  }
}

resource "aws_subnet" "canary_subnet_pub_a" {
  vpc_id                  = aws_vpc.canary_vpc.id
  cidr_block              = "192.168.0.32/27"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "canary_subnet_pub_a",
  }
}

resource "aws_subnet" "canary_subnet_pub_b" {
  vpc_id                  = aws_vpc.canary_vpc.id
  cidr_block              = "192.168.0.64/27"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
    Name = "canary_subnet_pub_b",
  }
}

resource "aws_subnet" "canary_subnet_pri_a" {
  vpc_id                  = aws_vpc.canary_vpc.id
  cidr_block              = "192.168.0.96/27"
  availability_zone       = "us-east-1a"
  tags = {
    Name = "canary_subnet_pri_a",
  }
}

resource "aws_subnet" "canary_subnet_pri_b" {
  vpc_id                  = aws_vpc.canary_vpc.id
  cidr_block              = "192.168.0.128/27"
  availability_zone       = "us-east-1b"
  tags = {
    Name = "canary_subnet_pri_b",
  }
}

resource "aws_route_table" "canary_pub_route_table" {
  vpc_id = aws_vpc.canary_vpc.id
}

resource "aws_route" "canary_pub_route" {
  route_table_id         = aws_route_table.canary_pub_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.canary_igw.id
}

resource "aws_route_table_association" "canary_pub_subnet_a_association" {
  subnet_id      = aws_subnet.canary_subnet_pub_a.id
  route_table_id = aws_route_table.canary_pub_route_table.id
}

resource "aws_route_table_association" "canary_pub_subnet_b_association" {
  subnet_id      = aws_subnet.canary_subnet_pub_b.id
  route_table_id = aws_route_table.canary_pub_route_table.id
}

resource "aws_security_group" "canary_sg_pub" {
  name_prefix = "canary-sg-pub-"
  vpc_id      = aws_vpc.canary_vpc.id

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks = ["${data.external.current_ip.result.ip}/32"]
  }

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["${data.external.current_ip.result.ip}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_lb" "canary_alb" {
  security_groups    = [aws_security_group.canary_sg_pub.id]
  subnets            = [aws_subnet.canary_subnet_pub_a.id, aws_subnet.canary_subnet_pub_b.id]
  tags = {
    Name = "canary_alb",
  }
}

resource "aws_lb_target_group" "canary_alb_tg_1" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.canary_vpc.id
  tags = {
    Name = "canary_alb_tg_1"
  }
}

resource "aws_lb_target_group" "canary_alb_tg_2" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.canary_vpc.id
  tags = {
    Name = "canary_alb_tg_2"
  }
}

resource "aws_security_group" "canary_sg_pri" {
  name_prefix = "canary-sg-pri-"
  vpc_id      = aws_vpc.canary_vpc.id

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    security_groups = [aws_security_group.canary_sg_pub.id]
  }

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    security_groups = [aws_security_group.canary_sg_pub.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_launch_template" "canary_launch_template_1" {
  name  = "canary_launch_template_1"
  image_id      = "ami-01bc990364452ab3e"
  instance_type = "t2.micro"

  instance_market_options {
    market_type = "spot"
  }

  key_name = "key_1"
  user_data = filebase64("web_install_1.sh")
  vpc_security_group_ids = [aws_security_group.canary_sg_pri.id]
}

resource "aws_autoscaling_group" "canary_asg_1" {
  name_prefix         = "canary-asg-2"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.canary_alb_tg_1.arn]
  vpc_zone_identifier = [aws_subnet.canary_subnet_pri_a.id]

  launch_template {
    id      = aws_launch_template.canary_launch_template_1.id
    version = aws_launch_template.canary_launch_template_2.latest_version
  }

  tag {
    key                 = "Name"
    value               = "canary_asg_1"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "AppVersion"
    value               = "1.0.0"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "ApplicationID"
    value               = "canary_asg_1"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "canary_asp_scale_in_1" {
  name                   = "canary-aps-scale-in-1"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.canary_asg_1.name
}

resource "aws_autoscaling_policy" "canary_asp_scale_out_1" {
  name                   = "canary-aps-scale-out-1"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.canary_asg_1.name
}

resource "aws_cloudwatch_metric_alarm" "canary_cw_alarm_high_1" {
  alarm_name          = "canary-cw-alarm-high-1"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_autoscaling_policy.canary_asp_scale_out_1.arn]
  dimensions          = {
    AutoScalingGroupName = aws_autoscaling_group.canary_asg_1.name
  }
}

resource "aws_cloudwatch_metric_alarm" "canary_cw_alarm_low_1" {
  alarm_name          = "canary-cw-alarm-low-1"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_actions       = [aws_autoscaling_policy.canary_asp_scale_in_1.arn]
  dimensions          = {
    AutoScalingGroupName = aws_autoscaling_group.canary_asg_1.name
  }
}

resource "aws_launch_template" "canary_launch_template_2" {
  name          = "canary_launch_template_2"
  image_id      = "ami-01bc990364452ab3e"
  instance_type = "t2.micro"

  instance_market_options {
    market_type = "spot"
  }

  key_name               = "key_1"
  user_data              = filebase64("web_install_2.sh")
  vpc_security_group_ids = [aws_security_group.canary_sg_pri.id]
}

resource "aws_autoscaling_group" "canary_asg_2" {
  name_prefix         = "canary-asg-2"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.canary_alb_tg_2.arn]
  vpc_zone_identifier = [aws_subnet.canary_subnet_pri_b.id]

  launch_template {
    id      = aws_launch_template.canary_launch_template_2.id
    version = aws_launch_template.canary_launch_template_2.latest_version
  }

  tag {
    key                 = "Name"
    value               = "canary_asg_2"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "AppVersion"
    value               = "1.1.0"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "ApplicationID"
    value               = "canary_asg_2"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "canary_asp_scale_in_2" {
  name                   = "canary-aps-scale-in-2"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.canary_asg_2.name
}

resource "aws_autoscaling_policy" "canary_asp_scale_out_2" {
  name                   = "canary-aps-scale-out-2"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.canary_asg_2.name
}

resource "aws_cloudwatch_metric_alarm" "canary_cw_alarm_high_2" {
  alarm_name                = "canary-cw-alarm-high-2"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 80
  alarm_actions = [aws_autoscaling_policy.canary_asp_scale_out_2.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.canary_asg_2.name
  }
}

resource "aws_cloudwatch_metric_alarm" "canary_cw_alarm_low_2" {
  alarm_name                = "canary-cw-alarm-low-2"
  comparison_operator       = "LessThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 10
  alarm_actions = [aws_autoscaling_policy.canary_asp_scale_in_2.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.canary_asg_2.name
  }
}

resource "aws_lb_listener" "canary_alb_listener" {
  load_balancer_arn = aws_lb.canary_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"

    forward {
      target_group {
        arn = aws_lb_target_group.canary_alb_tg_1.arn
        weight = lookup(local.traffic_dist_map[var.distribution], "old", 80)
      }

      target_group {
        arn = aws_lb_target_group.canary_alb_tg_2.arn
        weight = lookup(local.traffic_dist_map[var.distribution], "new", 20)
      }

      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }
}

resource "aws_instance" "instance_x" {
  ami                         = "ami-01bc990364452ab3e"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.canary_subnet_pub_a.id
  key_name                    = "key_1"
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.canary_sg_pub.id]
  instance_market_options{
    market_type = "spot"
  }
  tags = {
    Name = "instance_x",
  }
}

resource "aws_eip" "canary_eip" {
  domain = "vpc"
  tags = {
    Name = "canary_eip"
  }
}

resource "aws_nat_gateway" "canary_NAT" {
  allocation_id = aws_eip.canary_eip.id
  subnet_id     = aws_subnet.canary_subnet_pub_a.id

  tags = {
    Name = "canary_NAT"
  }

  depends_on = [aws_internet_gateway.canary_igw]
}

resource "aws_route_table" "canary_NAT_route_table" {
  vpc_id = aws_vpc.canary_vpc.id
}

resource "aws_route" "canary_NAT_route" {
  route_table_id         = aws_route_table.canary_NAT_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.canary_NAT.id
}

resource "aws_route_table_association" "canary_pri_subnet_a_association" {
  subnet_id      = aws_subnet.canary_subnet_pri_a.id
  route_table_id = aws_route_table.canary_NAT_route_table.id
}

resource "aws_route_table_association" "canary_pri_subnet_b_association" {
  subnet_id      = aws_subnet.canary_subnet_pri_b.id
  route_table_id = aws_route_table.canary_NAT_route_table.id
}