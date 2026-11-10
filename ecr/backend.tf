terraform {
  backend "s3" {
    bucket = "voxenta-terraform-state-be"
    key    = "ecr/terraform.tfstate"
    region = "ap-southeast-1"
  }
}
