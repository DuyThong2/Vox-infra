variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name" {
  type    = string
  default = "voxenta"
}

variable "repo_names" {
  description = "ECR repositories to create -- one per Docker-image-producing backend service."
  type        = set(string)
  default     = ["vox-app", "vox-streaming", "vox-agents"]
}
