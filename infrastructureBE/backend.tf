terraform {
  backend "s3" {
    bucket = "voxenta-terraform-state-be"
    key    = "eks/backend/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

