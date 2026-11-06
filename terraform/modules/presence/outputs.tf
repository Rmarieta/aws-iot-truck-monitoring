output "presence_lambda_name" {
  value = aws_lambda_function.presence.function_name
}

output "presence_rule_name" {
  value = aws_iot_topic_rule.presence.name
}
