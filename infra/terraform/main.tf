# The Droplet, imported (#533). This describes what exists, and nothing applies it.
#
# DNS is NOT here: seandesmet.com's nameservers are Squarespace's, so the records
# are managed there by hand (RUNBOOK §8). The droplet's ID is given on the command
# line at import, and the state, which holds its address, is never committed.
# infra/README.md, "Terraform", has the steps. The token comes from
# DIGITALOCEAN_TOKEN, on the Mac only.
terraform {
  required_version = "= 1.17.1"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "= 2.106.0"
    }
  }

  # Its path is given at init, outside the throwaway clone. Losing the file means
  # running import again, which is accepted rather than adding a remote backend.
  backend "local" {}
}

provider "digitalocean" {}

resource "digitalocean_droplet" "main" {
  name   = "sean-mars"
  region = "nyc1"
  size   = "s-1vcpu-2gb"
  # The ID, not a slug: DigitalOcean retired this Ubuntu 24.04 image's slug, so the
  # API reports none, and naming a current image would plan a replacement.
  image = "195932981"
  ipv6  = true

  lifecycle {
    prevent_destroy = true
  }
}
