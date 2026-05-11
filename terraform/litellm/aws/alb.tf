resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  idle_timeout = 120
}

# Target groups — one per component. IP target type because Fargate tasks
# are addressed by ENI IP, not instance.

resource "aws_lb_target_group" "gateway" {
  name        = "${var.name}-gateway"
  port        = 4000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/health/readiness"
    matcher             = "200-299"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.name}-backend"
  port        = 4001
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/health/readiness"
    matcher             = "200-299"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group" "ui" {
  name        = "${var.name}-ui"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/healthz"
    matcher             = "200-299"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

# HTTP listener. The default action is the backend (management API), and we
# add higher-priority rules that route UI assets to the UI target group and
# LLM data-plane prefixes to the gateway.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

# UI exact paths (/, /favicon.ico, /ui) — priority 10.
resource "aws_lb_listener_rule" "ui_exact" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }

  condition {
    path_pattern {
      values = local.ui_exact_paths
    }
  }
}

# UI prefix paths (/_next/*, /litellm-asset-prefix/*, /assets/*, /ui/*) — priority 20.
resource "aws_lb_listener_rule" "ui_prefix" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }

  condition {
    path_pattern {
      values = local.ui_path_prefixes
    }
  }
}

# Gateway prefix rules — one per chunk-of-5 because ALB caps a path-pattern
# condition at 5 values. Priorities 100..(100 + N).
resource "aws_lb_listener_rule" "gateway" {
  for_each = { for idx, chunk in local.gateway_path_chunks : idx => chunk }

  listener_arn = aws_lb_listener.http.arn
  priority     = 100 + tonumber(each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  condition {
    path_pattern {
      values = each.value
    }
  }
}
