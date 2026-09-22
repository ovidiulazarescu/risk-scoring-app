variable "create_oidc_provider" {
  type        = bool
  default     = false
  description = <<-EOT
    An AWS account can only have one OIDC provider for token.actions.githubusercontent.com.
    Default is false because this stack is expected to share an account with other GitHub
    OIDC-based projects (e.g. risk-api), which already created the provider. Set to true
    only if this is the first GitHub-OIDC stack in the account.
  EOT
}

data "tls_certificate" "github_oidc" {
  count = var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc[0].certificates[0].sha1_fingerprint]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # GitHub's sub claim carries immutable owner and repo IDs: repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:...
      values = ["repo:ovidiulazarescu@69583998/risk-scoring-app@REPLACE_WITH_REPO_ID:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_deployer" {
  name               = "github-actions-deployer-risk-scoring-app"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy" "deployer_ecs" {
  name = "ecs-deploy"
  role = aws_iam_role.github_actions_deployer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcsManage"
        Effect   = "Allow"
        Action   = ["ecs:*"]
        Resource = "*"
      },
      {
        Sid      = "ElbManage"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]
        Resource = "*"
      },
      {
        Sid      = "Ec2Describe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Sid      = "CloudFrontManage"
        Effect   = "Allow"
        Action   = ["cloudfront:*"]
        Resource = "*"
      },
      {
        Sid      = "LogsManage"
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/risk-scoring-app*"
      },
      {
        Sid    = "FrontendBucket"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::risk-scoring-app-frontend-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::risk-scoring-app-frontend-${data.aws_caller_identity.current.account_id}/*"
        ]
      },
      {
        Sid    = "PassEcsRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
      }
    ]
  })
}

# Everything `terraform apply` in CI needs, scoped to this stack's resources
resource "aws_iam_role_policy" "deployer_terraform" {
  name = "terraform-apply"
  role = aws_iam_role.github_actions_deployer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::tf-state-${data.aws_caller_identity.current.account_id}"
      },
      {
        # includes the .tflock object used by use_lockfile
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::tf-state-${data.aws_caller_identity.current.account_id}/risk-scoring-app/*"
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "EcrRepository"
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/risk-scoring-app"
      },
      {
        Sid    = "ManageStackIam"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn,
          aws_iam_role.github_actions_deployer.arn
        ]
      }
    ]
  })
}
