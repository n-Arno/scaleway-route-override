terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
      version = ">= 2.33"
    }
  }
  required_version = ">= v0.13"
}

provider "scaleway" {}
