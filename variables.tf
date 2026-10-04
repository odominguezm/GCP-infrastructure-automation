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
}

variable "zone" {
  type        = string
  description = "Zone the instance lives in."
  default     = "us-central1-a"
}

variable "required_apis" {
  type        = list(string)
  description = <<-EOT
    GCP APIs enabled on the project.
    storage.googleapis.com is required for the off-site backup bucket, and
    iap.googleapis.com for the SSH tunnel that replaces direct port 22 access.
  EOT
  default     = ["compute.googleapis.com", "storage.googleapis.com", "iap.googleapis.com"]
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
  description = "Name of the reserved static public IP resource."
  default     = "instancia-devops-gcp-ip"
}

# ---------- Network exposure ----------
variable "web_source_ranges" {
  type        = list(string)
  description = "Source ranges allowed to reach ports 80/443."
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
  description = "Machine type. e2-micro is inside the free tier in us-central1."
  default     = "e2-micro"

  validation {
    condition     = can(regex("^e2-(micro|small)$", var.machine_type))
    error_message = "This project targets the free tier: use e2-micro or e2-small."
  }
}

variable "image" {
  type        = string
  description = "Guest OS image for the instance."
  default     = "ubuntu-os-cloud/ubuntu-2404-lts"
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
    Bucket location. A regional bucket in the same region as the instance keeps
    the upload on the free egress tier; multi-region does not.
  EOT
  default     = "us-central1"
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
    Days to keep disk snapshots. Snapshots cover the whole instance, including
    the Docker volumes that the database backup script does not touch.
  EOT
  default     = 7
}

variable "enable_snapshots" {
  type        = bool
  description = <<-EOT
    Scheduled disk snapshots. Each snapshot costs roughly $0.026/GB-month on the
    free tier's persistent disk class, so 30 GB x 7 days stays under a dollar.
    Set to false to skip them.
  EOT
  default     = true
}