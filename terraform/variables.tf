variable "aws_region" {
  default = "us-east-1"
}

variable "app_name" {
  default = "multi-env-deploy"
}

variable "environments" {
  default = ["dev", "staging", "prod"]
}

variable "github_repo" {
  description = "multi env deployment repo"
  type = string
}