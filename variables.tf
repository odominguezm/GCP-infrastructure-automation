# ============================================================
# Terraform input variables
# Copy terraform.tfvars.example to terraform.tfvars and adjust.
# ============================================================

# ---------- Project identity ----------
variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "Region where the infrastructure is deployed."
  default     = "us-central1"

  # The Always Free e2-micro quota only exists in these three US regions.
  # Deploying anywhere else silently turns a free lab into a billed one.
  validation {
    condition     = contains(["us-central1", "us-west1", "us-east1"], var.region)
    error_message = "region must be us-central1, us-west1 or us-east1: the Always Free e2-micro is only offered there."
  }
}

variable "zone" {
  type        = string
  description = "Zone the instance lives in. Must belong to var.region."
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must belong to the selected region, for example us-central1-a."
  }
}

variable "required_apis" {
  type        = list(string)
  description = <<-EOT
    GCP APIs enabled on the project.
    compute for the VM and network, storage for the off-site backup bucket,
    iap for the SSH tunnel that replaces public port 22, and iam because
    Terraform creates a dedicated service account for the instance.
  EOT
  default = [
    "compute.googleapis.com",
    "storage.googleapis.com",
    "iap.googleapis.com",
    "iam.googleapis.com",
  ]
}

# ---------- Network ----------
variable "network_name" {
  type        = string
  description = "VPC name."
  default     = "vpc-devops-lab"
}

variable "subnet_name" {
  type        = string
  description = "Subnet name."
  default     = "subnet-devops"
}

variable "subnet_cidr" {
  type        = string
  description = "Subnet CIDR range in RFC 1918 format."
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR, for example 10.0.1.0/24."
  }
}

variable "enable_egress" {
  type        = bool
  description = <<-EOT
    Attach an ephemeral external IP so the instance can reach the internet.

    This opens no inbound port. It exists because a VM without an external IP
    (or Cloud NAT, which is billed hourly) cannot reach apt mirrors, the Docker
    registry or packages.cloud.google.com, so a deployment cannot install
    anything.

    Turn it on before deploying and off afterwards. The Always Free tier
    includes one hour of external IP per account per month, so a normal deploy
    window costs 0.00 to a few cents. Leaving it on 24/7 costs
    $0.005/hour (~$3.65/month).
  EOT
  default     = false
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = <<-EOT
    Source ranges allowed to reach port 22.
    Default: the Identity-Aware Proxy range (35.235.240.0/20).
  EOT
  default     = ["35.235.240.0/20"]

  # Guards against the most common security regression: opening SSH to the
  # entire internet.
  validation {
    condition     = !contains(var.ssh_source_ranges, "0.0.0.0/0")
    error_message = <<-EOT
      0.0.0.0/0 in ssh_source_ranges leaves SSH open to the whole internet.
      Use the IAP range (35.235.240.0/20) or your corporate public IP range.
    EOT
  }
}

# ---------- Instance ----------
variable "instance_name" {
  type        = string
  description = "Compute Engine instance name."
  default     = "instancia-devops-gcp"
}

variable "machine_type" {
  type        = string
  description = "Machine type. e2-micro is the only Compute Engine shape included in the Always Free tier."
  default     = "e2-micro"

  validation {
    condition     = var.machine_type == "e2-micro"
    error_message = "machine_type must be e2-micro: e2-small and larger are billed and are not part of the Always Free tier."
  }
}

variable "image" {
  type        = string
  description = "Guest OS image for the instance."
  # 22.04 LTS is used by the Ansible playbook and the Docker/Ansible packages it
  # installs. Changing the family recreates the boot disk, so it is a deliberate
  # migration, not a routine bump.
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "boot_disk_type" {
  type        = string
  description = <<-EOT
    Boot disk class of the instance.
    Only pd-standard is part of the Always Free tier (30 GB-months). pd-balanced
    and pd-ssd are billed, and disk type is ForceNew, so changing it also
    replaces the VM and its data.
  EOT
  default     = "pd-standard"

  validation {
    condition     = var.boot_disk_type == "pd-standard"
    error_message = "boot_disk_type must be pd-standard: it is the only disk class covered by the Always Free tier."
  }
}

variable "disk_size_gb" {
  type        = number
  description = "Boot disk size in GB. 30 GB is the free tier limit."
  default     = 30

  validation {
    condition     = var.disk_size_gb >= 10 && var.disk_size_gb <= 30
    error_message = "disk_size_gb must be between 10 and 30 to stay on the free tier."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Prevents the instance from being deleted by mistake."
  default     = true
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to resources, for traceability and billing."
  default = {
    environment = "dev"
    managed_by  = "terraform"
    project     = "gcp-devops-lab"
  }
}

# ---------- Access ----------
variable "ssh_user" {
  type        = string
  description = "Image default user, used for the SSH key bootstrap."
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the bootstrap. Takes precedence over ssh_public_key_path. Convenient in CI."
  default     = null
  nullable    = true
}

variable "ssh_public_key_path" {
  type        = string
  description = "Local path to the SSH public key used for the bootstrap. `~` is expanded."
  default     = "~/.ssh/id_deploy_gcp.pub"
}

# ---------- Disaster recovery ----------
variable "backup_service_account_id" {
  type        = string
  description = <<-EOT
    Short id of the dedicated service account the instance runs as. Terraform
    appends `@<project_id>.iam.gserviceaccount.com`.

    A dedicated account rather than the default compute SA: the default one is
    shared across the project, commonly granted Editor, and cannot have its keys
    disabled, which makes it the wrong blast radius for a machine whose only
    job is writing backup objects.
  EOT
  default     = "devops-backup"
}

variable "backup_bucket_name" {
  type        = string
  description = <<-EOT
    Cloud Storage bucket that receives the database backups off-site.
    Leave empty to disable off-site backup entirely, which is useful for a first
    `terraform plan` before the bucket name is known.

    Bucket names are global and must be unique across all of Google Cloud, so
    append something personal: `<project_id>-backups-<suffix>`.
  EOT
  default     = ""
}

variable "backup_bucket_location" {
  type        = string
  description = <<-EOT
    Bucket location. Must be the same region as the instance: Cloud Storage's
    Always Free 5 GB only applies in us-central1, us-west1 and us-east1, and a
    same-region bucket keeps traffic on the free path.
  EOT
  default     = "us-central1"

  validation {
    # Only enforced when a bucket is actually created: a deployment without
    # off-site backups must not fail because an unused default lives elsewhere.
    condition = var.backup_bucket_name == "" || (
      contains(["us-central1", "us-west1", "us-east1"], var.backup_bucket_location) &&
      var.backup_bucket_location == var.region
    )
    error_message = "backup_bucket_location must be one of us-central1, us-west1 or us-east1, and must match var.region when backup_bucket_name is set."
  }
}

variable "backup_bucket_retention_days" {
  type        = number
  description = "Days a backup object is kept before the lifecycle rule deletes it. Must be at least the local retention."
  default     = 7

  validation {
    condition     = var.backup_bucket_retention_days >= 7
    error_message = "backup_bucket_retention_days below 7 would delete backups before the local retention window."
  }
}
