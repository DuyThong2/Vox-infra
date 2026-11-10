output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_arn" {
  value = aws_eks_cluster.main.arn
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_role_name" {
  value = aws_iam_role.node.name
}

output "node_instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "alb_irsa_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "karpenter_irsa_role_arn" {
  value = aws_iam_role.karpenter.arn
}

output "ebs_csi_irsa_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "eso_irsa_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "kms_key_arn" {
  value = aws_kms_key.secrets.arn
}

# ECR repo URLs now come from infrastructure/ecr/'s own outputs (vox_app_ecr_url,
# vox_streaming_ecr_url, vox_agents_ecr_url) -- that project is applied
# independently of this one, see its main.tf for why.

