variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "ecr_repo_vox" {
  type        = string
  description = "ECR repo name for the vox (Java) service"
  default     = "vox-app"
}

variable "ecr_repo_vox_streaming" {
  type        = string
  description = "ECR repo name for the vox-streaming (Go) service"
  default     = "vox-streaming"
}

variable "ecr_repo_agents" {
  type        = string
  description = "ECR repo name for the agents (Python) service"
  default     = "vox-agents"
}

# Must match infrastructureFE's var.name / var.domain_name -- the bucket name
# below is computed the same way infrastructureFE/main.tf computes it.
variable "fe_name" {
  type    = string
  default = "voxenta"
}

variable "fe_domain_name" {
  type        = string
  description = "Root FE domain (same value as infrastructureFE's domain_name)"
}
