# DIVE-6801: the DigitalOcean Marketplace 1-Click image for 5dive.
#
#   export DIGITALOCEAN_TOKEN=<a DigitalOcean API token with write scope>
#   packer init marketplace/digitalocean
#   packer build marketplace/digitalocean
#
# It makes a throwaway build Droplet, runs ../image/build.sh and ../image/cleanup.sh
# on it, then DigitalOcean's own clean-up and image check (the build fails on any
# FAIL the check reports), and saves the snapshot to submit in the Vendor Portal.
packer {
  required_plugins {
    digitalocean = {
      version = ">= 1.4.0"
      source  = "github.com/digitalocean/digitalocean"
    }
  }
}

variable "do_token" {
  type      = string
  default   = env("DIGITALOCEAN_TOKEN")
  sensitive = true
}

variable "region" {
  type    = string
  default = "nyc3"
}

# DigitalOcean's advice: build on the $6 size, so the 1-Click can be created on
# every size. The listing recommends a bigger one for running agents.
variable "size" {
  type    = string
  default = "s-1vcpu-1gb"
}

locals {
  snapshot_name = "5dive-ubuntu-24-04-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  # DigitalOcean's clean-up and image-check scripts, pinned to a commit and to
  # their sha256. A newer upstream copy is a deliberate bump of all three.
  do_tools_ref     = "b70878804ca27c01d5f5e882d26485defbaba210"
  do_cleanup_sha   = "5e2fe7ce30892a26ed2731238d9f26c40ae8b1084b070ce095f3b99ab1a2cc81"
  do_imgcheck_sha  = "91ff2b1880439c97ccdc49554c5ed8901b89ef250c8ac5fffe52811c68abac49"
}

source "digitalocean" "fivedive" {
  api_token     = var.do_token
  image         = "ubuntu-24-04-x64"
  region        = var.region
  size          = var.size
  ssh_username  = "root"
  snapshot_name = local.snapshot_name
}

build {
  sources = ["source.digitalocean.fivedive"]

  provisioner "shell" {
    inline = [
      "cloud-init status --wait || true",
      "mkdir -p /tmp/5dive-image",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../image/"
    destination = "/tmp/5dive-image"
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive", "LC_ALL=C"]
    inline = [
      "bash /tmp/5dive-image/build.sh",
      "bash /tmp/5dive-image/cleanup.sh",
      "rm -rf /tmp/5dive-image",
    ]
  }

  # Their clean-up empties /tmp, so both scripts wait in /root/do-tools.
  provisioner "shell" {
    inline = [
      "mkdir -p /root/do-tools && cd /root/do-tools",
      "curl -fsSL -o 90-cleanup.sh https://raw.githubusercontent.com/digitalocean/marketplace-partners/${local.do_tools_ref}/scripts/90-cleanup.sh",
      "curl -fsSL -o 99-img-check.sh https://raw.githubusercontent.com/digitalocean/marketplace-partners/${local.do_tools_ref}/scripts/99-img-check.sh",
      "echo '${local.do_cleanup_sha}  90-cleanup.sh' | sha256sum -c -",
      "echo '${local.do_imgcheck_sha}  99-img-check.sh' | sha256sum -c -",
      "bash 90-cleanup.sh",
      "bash 99-img-check.sh",
      "cd / && rm -rf /root/do-tools",
    ]
  }
}
