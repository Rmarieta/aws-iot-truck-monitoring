output "ecr_repository_url" {
  description = "Where the simulator image is pushed."
  value       = aws_ecr_repository.sim.repository_url
}

output "ecs_cluster_name" {
  description = "Cluster name for `aws ecs update-service` scaling."
  value       = aws_ecs_cluster.fleet.name
}

output "ecs_service_name" {
  description = "Service name — scale its desired-count to set the fleet size."
  value       = aws_ecs_service.sim.name
}

output "fleet_group_name" {
  value = aws_iot_thing_group.fleet.name
}
