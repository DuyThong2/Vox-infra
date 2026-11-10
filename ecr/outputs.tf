output "vox_app_ecr_url" {
  value = aws_ecr_repository.repos["vox-app"].repository_url
}

output "vox_streaming_ecr_url" {
  value = aws_ecr_repository.repos["vox-streaming"].repository_url
}

output "vox_agents_ecr_url" {
  value = aws_ecr_repository.repos["vox-agents"].repository_url
}
