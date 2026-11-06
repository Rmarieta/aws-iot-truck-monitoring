# ===========================================================================
# fleet/ecs.tf — one Fargate task == one simulated truck
# ---------------------------------------------------------------------------
# Scaling the service's desired-count to N gives N trucks. Each task, on
# start, derives a stable short id from its own task ARN, self-registers as a
# thing in the fleet group, publishes telemetry, and deregisters on SIGTERM
# (graceful stop only — a hard kill may leave an orphan thing, acceptable for
# a disposable demo). Tasks run in the account's DEFAULT VPC public subnets
# with public IPs: no NAT gateway (which would cost ~$32/mo for nothing). In
# production these would be private subnets egressing via NAT or a VPC
# endpoint — the deliberate shortcut, documented.
# ===========================================================================

# --- Container image registry ---------------------------------------------
resource "aws_ecr_repository" "sim" {
  name                 = "${var.name_prefix}-fleet-sim"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # disposable demo: let `terraform destroy` clean images

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Default VPC networking (reused, not created) --------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Egress-only SG: tasks need outbound TLS to IoT Core + AWS APIs; nothing
# inbound.
resource "aws_security_group" "sim" {
  name        = "${var.name_prefix}-fleet-sim"
  description = "Simulated fleet tasks - egress only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (IoT 8883, AWS APIs 443)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ECS cluster -----------------------------------------------------------
resource "aws_ecs_cluster" "fleet" {
  name = "${var.name_prefix}-fleet"
}

# --- Logs ------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sim" {
  name              = "/ecs/${var.name_prefix}-fleet-sim"
  retention_in_days = 7
}

# --- IAM: execution role (pull image, write logs, read SSM cert) -----------
resource "aws_iam_role" "execution" {
  name = "${var.name_prefix}-fleet-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role injects the cert/key from SSM into the container env.
resource "aws_iam_role_policy" "execution_ssm" {
  name = "read-sim-cert"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [aws_ssm_parameter.sim_cert.arn, aws_ssm_parameter.sim_key.arn]
    }]
  })
}

# --- IAM: task role (what the running truck may do) ------------------------
# Least-privilege self-registration: create/delete ONLY truck-<6 chars> things
# (the `?` wildcards deliberately exclude the real device `truck-0`) and
# manage its own membership in the fleet group. It does NOT get iot:Publish via
# IAM — publishing is authorized by the X.509 policy over the MQTT connection.
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-fleet-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_register" {
  name = "self-register"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOwnThing"
        Effect = "Allow"
        Action = [
          "iot:CreateThing",
          "iot:DescribeThing",
          "iot:DeleteThing",
        ]
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:thing/truck-??????"
      },
      {
        # AttachThingPrincipal / DetachThingPrincipal are authorized against
        # BOTH the thing AND the certificate (principal) resource, so the
        # shared sim-fleet cert ARN must be granted alongside the thing wildcard
        # — otherwise IAM denies on the cert resource (the AccessDenied we hit).
        Sid    = "AttachOwnCert"
        Effect = "Allow"
        Action = [
          "iot:AttachThingPrincipal",
          "iot:DetachThingPrincipal",
        ]
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:thing/truck-??????",
          aws_iot_certificate.sim_fleet.arn,
        ]
      },
      {
        Sid    = "ManageGroupMembership"
        Effect = "Allow"
        Action = [
          "iot:AddThingToThingGroup",
          "iot:RemoveThingFromThingGroup",
        ]
        Resource = [
          aws_iot_thing_group.fleet.arn,
          "arn:aws:iot:${var.region}:${var.account_id}:thing/truck-??????",
        ]
      },
      {
        # Attaching the shared policy to the shared cert is already done in
        # Terraform; the task only needs to attach the cert to its new thing,
        # which ManageOwnThing's AttachThingPrincipal covers. The cert ARN is
        # passed in via env so the task does not need to look it up.
        Sid      = "DescribeEndpoint"
        Effect   = "Allow"
        Action   = ["iot:DescribeEndpoint"]
        Resource = "*"
      },
    ]
  })
}

# --- Task definition -------------------------------------------------------
resource "aws_ecs_task_definition" "sim" {
  family                   = "${var.name_prefix}-fleet-sim"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "truck"
    image     = "${aws_ecr_repository.sim.repository_url}:latest"
    essential = true

    environment = [
      { name = "IOT_ENDPOINT", value = var.iot_endpoint },
      { name = "FLEET_GROUP", value = aws_iot_thing_group.fleet.name },
      { name = "SIM_CERT_ARN", value = aws_iot_certificate.sim_fleet.arn },
      { name = "TELEMETRY_INTERVAL", value = tostring(var.publish_interval_seconds) },
      { name = "OFFLINE_PCT", value = tostring(var.offline_pct) },
    ]

    # Cert + key injected from SSM by the execution role (never in the image).
    secrets = [
      { name = "SIM_CERT_PEM", valueFrom = aws_ssm_parameter.sim_cert.arn },
      { name = "SIM_PRIVATE_KEY", valueFrom = aws_ssm_parameter.sim_key.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.sim.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "truck"
      }
    }

    # Give the container time to deregister gracefully on scale-down.
    stopTimeout = 30
  }])
}

# --- Service: desired_count == fleet size ----------------------------------
# Starts at 0 so `terraform apply` does NOT launch trucks (and incur cost).
# `make fleet SIZE=N` scales it up; `make fleet-stop` scales it to 0.
resource "aws_ecs_service" "sim" {
  name            = "${var.name_prefix}-fleet-sim"
  cluster         = aws_ecs_cluster.fleet.id
  task_definition = aws_ecs_task_definition.sim.arn
  desired_count   = var.fleet_size
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.sim.id]
    assign_public_ip = true # public subnets, no NAT
  }

  # desired_count is driven by the Makefile (scale up/down), so don't let
  # Terraform fight those out-of-band changes.
  lifecycle {
    ignore_changes = [desired_count]
  }
}
