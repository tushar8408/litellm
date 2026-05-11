provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        "litellm:stack" = var.name
        "managed-by"    = "terraform"
      },
      var.tags,
    )
  }
}
