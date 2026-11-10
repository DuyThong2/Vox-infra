output "vientrlenh_access_key_id" {
  description = "AWS_ACCESS_KEY_ID secret for vox / vox-streaming / vox-client-web repos"
  value       = aws_iam_access_key.vientrlenh.id
}

output "vientrlenh_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY secret for vox / vox-streaming / vox-client-web repos"
  value       = aws_iam_access_key.vientrlenh.secret
  sensitive   = true
}

output "duythong2_access_key_id" {
  description = "AWS_ACCESS_KEY_ID secret for the agents repo"
  value       = aws_iam_access_key.duythong2.id
}

output "duythong2_secret_access_key" {
  description = "AWS_SECRET_ACCESS_KEY secret for the agents repo"
  value       = aws_iam_access_key.duythong2.secret
  sensitive   = true
}
