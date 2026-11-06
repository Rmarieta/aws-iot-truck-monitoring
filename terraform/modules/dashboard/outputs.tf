output "api_base_url" {
  description = "HTTP API base URL. Readings: <url>/readings?device_id=truck-0"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "readings_url" {
  description = "Full readings endpoint for the map page."
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/readings"
}

output "dashboard_url" {
  description = "Hosted dashboard URL (CloudFront, HTTPS)."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}/"
}
