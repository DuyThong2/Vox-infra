provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Official AWS Load Balancer Controller IAM policy, pinned to the chart/app
# version in use on 2026-07-19. See:
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/
data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.4.2/docs/install/iam_policy.json"
}

locals {
  tags = {
    Project = var.name
  }

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  oidc_issuer     = aws_eks_cluster.main.identity[0].oidc[0].issuer
  oidc_issuer_key = replace(local.oidc_issuer, "https://", "")
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name                     = "${var.name}-vpc"
    "karpenter.sh/discovery" = var.cluster_name
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, {
    Name = "${var.name}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, {
    Name = "${var.name}-public-rt"
  })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                        = "${var.name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    "karpenter.sh/discovery"                    = var.cluster_name
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = false
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  # aws_eks_access_entry.karpenter_node_role (below) needs the modern Access
  # Entry API, which EKS only allows when authentication_mode is API or
  # API_AND_CONFIG_MAP -- clusters created without this block default to
  # CONFIG_MAP-only (legacy aws-auth ConfigMap), which rejects access-entry
  # creation with a 400. API_AND_CONFIG_MAP (not pure API) keeps aws-auth
  # ConfigMap compatibility too, in case anything still depends on it.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    # Must match the value AWS already applied by default when the cluster
    # was first created (implicit, since no access_config block existed then)
    # -- omitting this makes Terraform see true -> null, which forces a full
    # cluster replacement (this attribute can't be changed after creation).
    # authentication_mode itself CAN change in-place (CONFIG_MAP ->
    # API_AND_CONFIG_MAP -> API is AWS's supported one-way upgrade path).
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

resource "aws_ec2_tag" "cluster_security_group_karpenter_discovery" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node-instance-profile"
  role = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "static" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-static-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_access_entry" "karpenter_node_role" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

data "tls_certificate" "oidc" {
  url = local.oidc_issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = local.oidc_issuer

  tags = local.tags
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_key}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_key}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.alb_controller_policy.response_body

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "aws_iam_role" "karpenter" {
  name = "${var.cluster_name}-karpenter-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_key}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_key}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })

  tags = local.tags
}

# Karpenter controller IAM policy, transcribed statement-for-statement from
# AWS's own official source (not hand-invented) — the "Getting Started with
# Karpenter" CloudFormation template, NodeLifecyclePolicy + IAMIntegrationPolicy
# + EKSIntegrationPolicy + ResourceDiscoveryPolicy resources, fetched and
# reviewed 2026-07-19 from the v1.14.0 tag (latest release at the time):
# https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.14.0/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml
#
# Deliberately OMITTED vs. the official template: InterruptionPolicy,
# ZonalShiftPolicy, and the SQS interruption queue + EventBridge rules. Those
# exist purely to gracefully drain nodes on spot interruption / AWS health
# events. Both NodePools in this project use `capacityType: on-demand` only
# (no spot — see karpenter/nodepool-*.yaml), so the interruption queue has no
# spot-interruption traffic to consume; standing up an unused SQS queue + 5
# EventBridge rules would be scope creep for what it buys here. Revisit this
# if the NodePools ever switch to spot capacity.
resource "aws_iam_role_policy" "karpenter" {
  name = "${var.cluster_name}-karpenter-controller"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # NodeLifecyclePolicy / AllowScopedEC2InstanceAccessActions
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:capacity-reservation/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:placement-group/*"
        ]
      },
      {
        # NodeLifecyclePolicy / AllowScopedEC2LaunchTemplateAccessActions
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:launch-template/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        # NodeLifecyclePolicy / AllowScopedEC2InstanceActionsWithTags
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        # NodeLifecyclePolicy / AllowScopedResourceCreationTagging
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateFleet",
              "CreateLaunchTemplate"
            ]
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        # NodeLifecyclePolicy / AllowScopedResourceTagging
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          StringEqualsIfExists = {
            "aws:RequestTag/eks:eks-cluster-name" = var.cluster_name
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        # NodeLifecyclePolicy / AllowScopedDeletion
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.region}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        # IAMIntegrationPolicy / AllowPassingInstanceRole
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
          }
        }
      },
      {
        # IAMIntegrationPolicy / AllowScopedInstanceProfileCreationActions
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Action   = "iam:CreateInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                      = var.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        # IAMIntegrationPolicy / AllowScopedInstanceProfileTagActions
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Action   = "iam:TagInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                       = var.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"              = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        # IAMIntegrationPolicy / AllowScopedInstanceProfileActions
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        # EKSIntegrationPolicy / AllowAPIServerEndpointDiscovery
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:${data.aws_partition.current.partition}:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        # ResourceDiscoveryPolicy / AllowRegionalReadActions
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribePlacementGroups",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.region
          }
        }
      },
      {
        # ResourceDiscoveryPolicy / AllowSSMReadActions
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.region}::parameter/aws/service/*"
      },
      {
        # ResourceDiscoveryPolicy / AllowPricingReadActions
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
      {
        # ResourceDiscoveryPolicy / AllowUnscopedInstanceProfileListAction
        Sid      = "AllowUnscopedInstanceProfileListAction"
        Effect   = "Allow"
        Action   = "iam:ListInstanceProfiles"
        Resource = "*"
      },
      {
        # ResourceDiscoveryPolicy / AllowInstanceProfileReadActions
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = "iam:GetInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
      }
    ]
  })
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_key}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_key}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_key}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_key}:sub" = "system:serviceaccount:external-secrets:external-secrets"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_kms_key" "secrets" {
  description = "Vox Secrets Manager CMK"
  # AWS minimum (was 30) -- this project destroys/recreates infrastructureBE
  # between test cycles; each destroy leaves the old key billed at $1/mo while
  # "pending deletion" regardless of this value (AWS enforces a real waiting
  # period, can't skip it), so shortening it to the floor minimizes that
  # lingering per-cycle cost instead of carrying it for a full month.
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowExternalSecretsDecrypt"
        Effect = "Allow"
        Principal = {
          # Built as a plain string, NOT aws_iam_role.external_secrets.arn --
          # a direct resource-attribute reference here creates a real
          # Terraform dependency edge (KMS key -> IAM role -> OIDC provider
          # -> cluster), which makes `terraform destroy -target=aws_eks_cluster.main`
          # ALSO destroy this key and every secret encrypted with it (they
          # depend on the key) -- confirmed live via a real plan run, this
          # is exactly what the narrow-destroy playbook promises never
          # happens. IAM role ARNs are fully deterministic from account ID +
          # role name, so this string produces the IDENTICAL runtime value
          # with zero functional change, just without the artificial
          # destroy-order coupling.
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-external-secrets-irsa"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/vox-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadVoxSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:vox/*"
        ]
      },
      {
        Sid    = "DecryptVoxSecrets"
        Effect = "Allow"
        Action = "kms:Decrypt"
        # Alias ARN (deterministic name, "alias/vox-secrets" -- matches
        # aws_kms_alias.secrets below), NOT aws_kms_key.secrets.arn -- same
        # reasoning as the KMS key policy's AllowExternalSecretsDecrypt
        # statement above: a direct resource-attribute reference here would
        # bridge this cluster-tied resource (aws_iam_role_policy.external_secrets
        # depends on aws_iam_role.external_secrets, which depends on the
        # cluster's OIDC provider) to the KMS key, pulling the key (and every
        # secret encrypted with it) into a `terraform destroy
        # -target=aws_eks_cluster.main` plan -- confirmed live, this exact
        # bridge is what did it even after the KMS key's own policy was
        # already fixed. AWS resolves alias ARNs to the underlying CMK for
        # kms:Decrypt authorization, so this grants the identical real
        # permission with zero functional change.
        Resource = "arn:${data.aws_partition.current.partition}:kms:${var.region}:${data.aws_caller_identity.current.account_id}:alias/vox-secrets"
      }
    ]
  })
}

# ECR repos live in their own Terraform project (infrastructure/ecr/), not
# here -- see that project's main.tf comment for why. This file used to
# create them directly; moved out so they never get caught in an
# infrastructureBE destroy/recreate cycle, structurally (not just by
# remembering the right `-target` flags every time).

resource "aws_secretsmanager_secret" "vox" {
  for_each = var.secret_names

  name       = each.key
  kms_key_id = aws_kms_key.secrets.arn

  tags = local.tags
}

# --- coturn hostNetwork migration (2026-07-20) ---
# coturn's relay port range moved off the Service/NLB (AWS hard-caps NLBs at
# 50 listeners total, non-adjustable -- Service Quota L-57A373D6, confirmed
# live via a real CreateListener TooManyListeners error) to hostNetwork:
# true, binding straight to a node's real IP + a wide UDP range opened via
# Security Group instead (SGs have no such per-rule-count limit). This
# EIP gives that node a STABLE public address -- without it, a node replaced
# by Karpenter/AMI rotation would silently change coturn's address, breaking
# every TURN_URL client config until someone noticed and updated it (same
# category of problem the NLB had before, just worse since there's no
# DNS-based Service abstracting it away anymore).
#
# Pinned to the STATIC node group specifically (eks.amazonaws.com/nodegroup:
# vox-eks-static-ng, coturn's nodeSelector in vox-helm/charts/coturn/values.yaml)
# because it's NOT subject to Karpenter's consolidation/churn -- the `general`
# NodePool's nodes get replaced routinely, which would make ANY EIP pinning
# strategy pointless there.
#
# NOT auto-associated by Terraform -- the static node group's actual EC2
# instance is managed by an underlying ASG (aws_eks_node_group.static), not
# a directly Terraform-owned aws_instance resource, so there's no stable
# resource reference to attach this to declaratively. Associate manually
# after apply (see runbook.md's coturn hostNetwork section for the exact
# command) and RE-ASSOCIATE if the static node is ever replaced -- this is a
# real gap, not automated end-to-end. A future improvement would be a small
# self-associating init container (IRSA + ec2:AssociateAddress, matching the
# node's own instance ID at pod startup) instead of this manual step.
resource "aws_eip" "coturn" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${var.name}-coturn-relay"
  })
}

# Opens the FULL IANA ephemeral port range (49152-65535, ~16000 ports) for
# UDP relay traffic straight to nodes -- deliberately much wider than the
# 48-port pool actually configured in coturn's values.yaml right now (that
# limit no longer exists on this path), so raising coturn's relay pool later
# needs zero Terraform/SG changes, only a values.yaml edit. Scoped to the
# same shared cluster security group nodes already use (see the SGs check
# during this migration: all 3 running nodes shared sg via
# aws_eks_cluster.main's auto-created cluster SG) -- NOT the static node
# specifically, since Security Group rules apply to the SG as a whole, not
# to individual instances; only the actual EIP association below is what
# scopes this to one node.
resource "aws_security_group_rule" "coturn_relay_hostnetwork" {
  type              = "ingress"
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port         = 49152
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "coturn TURN relay (hostNetwork) -- exam WebRTC media, see infrastructureBE/main.tf coturn section"
}

# Cổng ĐIỀU KHIỂN của TURN, mở thẳng vào node giống dải relay ở trên.
#
# Thiếu rule này là lỗ hổng còn sót của lần chuyển sang hostNetwork (2026-07-20): lúc đó chỉ mở
# dải relay 49152-65535, còn 3478/3479 vẫn dựa vào Service/NLB -- đúng khi client còn trỏ vào
# hostname NLB, nhưng SAI từ khi TURN_URL trỏ thẳng EIP của node. Traffic tới EIP đến từ
# internet (0.0.0.0/0) chứ không qua NLB, mà rule targetGroupBinding chỉ cho phép nguồn là
# security group của NLB -- nên gói STUN/TURN allocate rơi hết.
#
# Xác nhận thật 2026-08-11: gửi STUN Binding Request tới 52.76.15.255:3478 -> timeout. Hệ quả
# là KHÔNG bên nào (WPF lẫn pod agents) xin được relay candidate, ICE chỉ còn cặp host private
# 10.1.x.x <-> 192.168.x.x và luôn FAILED -> proctoring YOLO không bao giờ nhận được video.
#
# TCP 3479 mở kèm: chart coturn tách cổng TCP sang 3479 (xem vox-helm/charts/coturn/values.yaml
# ports.tcpService) và client có thể fallback sang TURN/TCP khi UDP bị chặn ở mạng thí sinh.
resource "aws_security_group_rule" "coturn_control_udp_hostnetwork" {
  type              = "ingress"
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port         = 3478
  to_port           = 3478
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "coturn TURN control port UDP (hostNetwork, dialed directly at the EIP)"
}

resource "aws_security_group_rule" "coturn_control_tcp_hostnetwork" {
  type              = "ingress"
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port         = 3479
  to_port           = 3479
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "coturn TURN control port TCP (hostNetwork, dialed directly at the EIP)"
}

output "coturn_relay_eip" {
  value       = aws_eip.coturn.public_ip
  description = "Static public IP for coturn's hostNetwork relay -- goes into TURN_URL (vox/coturn secret) and vox-helm/charts/coturn/values.yaml's coturn.coturn.externalIp"
}

