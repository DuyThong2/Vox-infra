variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name" {
  type    = string
  default = "voxenta"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR cho SSH"
  default     = "0.0.0.0/0"
}

variable "domain_name" {
  type        = string
  description = "Root domain cho Route53/ACM (vd: voxenta.net)"
}

variable "uploads_bucket_name" {
  type        = string
  description = "Bucket chứa tài nguyên câu hỏi, trùng AWS_S3_BUCKET trong vox-helm"
  default     = "vox-exam-uploads"
}

variable "uploads_local_dev_origins" {
  type        = list(string)
  description = "Origin máy dev được phép upload thẳng lên S3 (Vite mặc định cổng 5173)"
  default = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
  ]
}
