# DIVE-7479: the Vultr Marketplace image for 5dive.
#
#   export VULTR_API_KEY=<the Vultr vendor account's API key>
#   packer init marketplace/vultr
#   packer build marketplace/vultr
#
# It makes a throwaway build server, runs ../image/build.sh and ../image/cleanup.sh
# on it (the same two steps as the DigitalOcean image), then Vultr's own clean-up
# (clean_system from their helper script, pinned), and saves the snapshot. In the
# Vultr vendor portal, "Build App Image" from that snapshot, test it with "Deploy
# Image", then publish it (marketplace/README.md, Vultr).
packer {
  required_plugins {
    vultr = {
      version = ">= 2.7.0"
      source  = "github.com/vultr/vultr"
    }
  }
}

variable "vultr_api_key" {
  type      = string
  default   = env("VULTR_API_KEY")
  sensitive = true
}

variable "region" {
  type    = string
  default = "ewr"
}

# Vultr's advice: the smallest disk possible, so the app can be deployed on every
# plan; their examples build on marketplace-2c-2gb. If our account is refused that
# plan, vc2-1c-1gb (25 GB disk) is the smallest public plan the image fits.
variable "plan" {
  type    = string
  default = "marketplace-2c-2gb"
}

locals {
  # 2284 = "Ubuntu 24.04 LTS x64" (GET https://api.vultr.com/v2/os, 2026-11-01),
  # the same Ubuntu as the DigitalOcean and Linode listings.
  os_id         = "2284"
  snapshot_name = "5dive-ubuntu-24-04-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  # Vultr's helper script (install_cloud_init, clean_system), pinned to a commit
  # and to its sha256. A newer upstream copy is a deliberate bump of both.
  vultr_tools_ref  = "95768fc9438ac0024be291d328beca5844181c88"
  vultr_helper_sha = "1f0f4b53e64ef4e8af5fa7b3e7af98af56232475e8255d1d0439968a7e252ab3"
}

source "vultr" "fivedive" {
  api_key              = var.vultr_api_key
  os_id                = local.os_id
  plan_id              = var.plan
  region_id            = var.region
  snapshot_description = local.snapshot_name
  ssh_username         = "root"
  state_timeout        = "25m"
}

build {
  sources = ["source.vultr.fivedive"]

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

  # Vultr needs cloud-init (their helper installs Vultr's build only when the OS
  # has none; Ubuntu 24.04 has one), then our two steps.
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive", "LC_ALL=C"]
    inline_shebang   = "/bin/bash -e"
    inline = [
      "curl -fsSL -o /root/vultr-helper.sh https://raw.githubusercontent.com/vultr/vultr-marketplace/${local.vultr_tools_ref}/helper-scripts/vultr-helper.sh",
      "echo '${local.vultr_helper_sha}  /root/vultr-helper.sh' | sha256sum -c -",
      ". /root/vultr-helper.sh",
      "install_cloud_init latest",
      "bash /tmp/5dive-image/build.sh",
      "bash /tmp/5dive-image/cleanup.sh",
      "rm -rf /tmp/5dive-image",
    ]
  }

  # Vultr's own clean-up, last: updates, the `vultr` kernel option, temp files,
  # SSH keys, logs, history, machine id, zeroed free space and fstrim. It also
  # deletes /root/*.sh, the helper with it.
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline_shebang   = "/bin/bash -e"
    inline = [
      ". /root/vultr-helper.sh",
      "clean_system",
      "test ! -e /root/vultr-helper.sh",
    ]
  }
}
