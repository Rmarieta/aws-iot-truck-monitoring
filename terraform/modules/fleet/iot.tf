# ===========================================================================
# fleet/iot.tf — simulated-fleet IoT identity
# ---------------------------------------------------------------------------
# The simulated trucks are a DIFFERENT concern from the single real device
# (truck-0, in iot_core): they are disposable load generators. They share ONE
# certificate (the `sim-fleet` identity) rather than one cert per truck —
# a deliberate shortcut for a spin-up/tear-down demo. Production onboards each
# device with its OWN cert via Fleet Provisioning (claim cert -> provisioning
# template -> per-device cert); see the README. What is kept faithful here:
#   * each truck is a REAL thing in the registry, created at RUNTIME by the
#     task itself (fleet population is operational data, not Terraform state);
#   * they live in a thing GROUP for fleet-wide policy / jobs / Defender;
#   * the policy is scoped PER-THING with ${iot:Connection.Thing.ThingName},
#     so the shared cert still only lets each truck touch its own topics.
# ===========================================================================

# Thing group — the fleet-wide handle (Device Defender profiles, Jobs attach
# here). Members are added at runtime by each task, not declared in Terraform.
resource "aws_iot_thing_group" "fleet" {
  name = "${var.name_prefix}-fleet"

  properties {
    attribute_payload {
      attributes = {
        kind = "simulated"
      }
    }
  }
}

# One shared certificate for all simulated trucks.
resource "aws_iot_certificate" "sim_fleet" {
  active = true
}

# ThingName-scoped policy: the SAME shape as the real device policy, but the
# concrete device id is replaced by the policy variable, so one policy covers
# every truck and each is still confined to its own topics. The
# client-id must equal the thing name for the Connect variable to resolve —
# the simulator sets client-id = thing name for exactly this reason.
resource "aws_iot_policy" "sim_fleet" {
  name = "${var.name_prefix}-sim-fleet"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${var.region}:${var.account_id}:client/$${iot:Connection.Thing.ThingName}"
      },
      {
        Effect = "Allow"
        Action = "iot:Publish"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/telemetry/$${iot:Connection.Thing.ThingName}",
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/status/$${iot:Connection.Thing.ThingName}",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Subscribe"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topicfilter/coldchain/cmd/$${iot:Connection.Thing.ThingName}",
        ]
      },
      {
        Effect = "Allow"
        Action = "iot:Receive"
        Resource = [
          "arn:aws:iot:${var.region}:${var.account_id}:topic/coldchain/cmd/$${iot:Connection.Thing.ThingName}",
        ]
      },
    ]
  })
}

resource "aws_iot_policy_attachment" "sim_fleet" {
  policy = aws_iot_policy.sim_fleet.name
  target = aws_iot_certificate.sim_fleet.arn
}

# The shared cert material is handed to the tasks via SSM Parameter Store
# (SecureString), not baked into the image — the image stays credential-free
# and the cert can be rotated without a rebuild.
resource "aws_ssm_parameter" "sim_cert" {
  name  = "/${var.name_prefix}/fleet/cert-pem"
  type  = "SecureString"
  value = aws_iot_certificate.sim_fleet.certificate_pem
}

resource "aws_ssm_parameter" "sim_key" {
  name  = "/${var.name_prefix}/fleet/private-key"
  type  = "SecureString"
  value = aws_iot_certificate.sim_fleet.private_key
}
