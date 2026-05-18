output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "service_names" {
  value = { for env in var.environments : env => aws_ecs_service.app[env].name }
}