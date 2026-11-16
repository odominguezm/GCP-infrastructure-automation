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

variable "static_address_name" {
  type        = string
  description = "Name of the reserved static public IP resource. Only used when enable_public_ip = true."
  default     = "devops-lab-ip"
}

# ---------- Network exposure ----------
variable "enable_public_ip" {
  type        = bool
  description = <<-EOT
    Give the VM an external IP and open 80/443 to the internet.

    Default false: the Always Free tier covers the VM, its 30 GB standard disk
    and 1 GB/month of egress, but it does NOT cover external IP addresses.
    Google charges $0.005/hour (~$3.65/month) for a static or ephemeral IP in
    use on a standard VM, with only one free hour per month per account.

    With false, every administrative and web port is reached through an IAP
    tunnel (also free), and the deployment stays at $0.00 in Compute Engine.
    Set true only if a publicly reachable demo is worth the hourly address cost.
  EOT
  default     = false
}

variable "enable_egress" {
  type        = bool
  description = <<-EOT
    Attach an ephemeral external IP so the instance can reach the internet.

    This is NOT the same as enable_public_ip: it opens no inbound port, it only
    gives the VM a way out. Without an external IP (or Cloud NAT, which is
    billed hourly) a VM cannot reach apt mirrors, the Docker registry or
    packages.cloud.google.com, so a deployment cannot install anything.

    It exists because the first Ansible run needs egress even in the free
    profile. Turn it on before deploying and off afterwards: the Always Free
    tier includes one hour of external IP per account per month, so a deploy
    window costs 0.00 to a few cents. Leaving it on costs $0.005/hour
    (~$3.65/month).

    enable_public_ip = true implies this, so it does not need to be set too.
  EOT
  default     = false
}

variable "web_source_ranges" {
  type        = list(string)
  description = "Source ranges allowed to reach ports 80/443. Only used when enable_public_ip = true."
  default     = ["0.0.0.0/0"]
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

variable "enable_vpc_flow_logs" {
  type        = bool
  description = <<-EOT
    Enable VPC Flow Logs on the subnet.

    Default false: flow logs are billed per GiB ($0.25/GiB up to 10,240 GiB) and
    are not covered by the Always Free tier. On a lab with almost no traffic the
    monthly cost is negligible, but it is not zero. Set true when the audit
    trail is worth more than the line item.
  EOT
  default     = false
}

variable "enable_shielded_vm" {
  type        = bool
  description = "Enables vTPM, Secure Boot and integrity monitoring. Requires the organisation policy to allow it."
  default     = false
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

variable "snapshot_retention_days" {
  type        = number
  description = <<-EOT
    Days to keep scheduled disk snapshots. Only used when enable_snapshots is
    true. Snapshots cover the whole instance, including Docker volumes.
  EOT
  default     = 7

  validation {
    condition     = var.snapshot_retention_days >= 1 && var.snapshot_retention_days <= 7
    error_message = "snapshot_retention_days must be between 1 and 7 to bound snapshot storage cost."
  }
}

variable "enable_snapshots" {
  type        = bool
  description = <<-EOT
    Scheduled disk snapshots.

    Default false: snapshots are NOT part of the Compute Engine Always Free
    tier. A 30 GB boot disk with 7 daily incremental snapshots typically costs
    around $1/month, and that line item grows with retention. Keep it false for
    a strictly $0.00 lab; set it true when full-instance recovery is worth the
    small monthly charge. Off-site database backups in Cloud Storage remain
    free and enabled independently.
  EOT
  default     = false
}