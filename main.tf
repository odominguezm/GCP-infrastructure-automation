# ============================================================
# Terraform - GCP Single-Instance DevOps Lab
#
# Owns the network and the instance. The configuration of the
# services running inside the VM is handled by Ansible (see site.yml).
#
# Default profile: Always Free. No external IP, no public ports and no
# snapshots. Everything is reached through IAP, which is free.
# ============================================================

terraform {
  # 1.9 is the first release where an input-variable validation may reference
  # another input variable (zone checks region; bucket location checks region).
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Authentication uses Application Default Credentials:
#   gcloud auth application-default login
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Enable only the APIs the project actually needs (least privilege).
resource "google_project_service" "required_apis" {
  for_each = toset(var.required_apis)

  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# ------------------------------------------------------------
# 1. Network
# ------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.required_apis]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnet_name
  ip_cidr_range            = var.subnet_cidr
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  depends_on = [google_project_service.required_apis]
}

# ------------------------------------------------------------
# 2. Firewall
# ------------------------------------------------------------
# The only ingress rule. There is deliberately no 80/443 rule: Nginx Proxy
# Manager, Grafana, Prometheus, Alertmanager and the NPM admin panel are all
# reached through an SSH tunnel over IAP:
#
#   gcloud compute ssh <instance> --tunnel-through-iap --zone <zone> \
#     -L 3000:localhost:3000
#
# The loopback bindings in the compose files are a second barrier: even if this
# rule were widened by mistake, the admin ports would still refuse outside
# connections.
resource "google_compute_firewall" "allow_ssh_iap" {
  name        = "${var.network_name}-allow-ssh-iap"
  description = "SSH restricted to the Identity-Aware Proxy range."
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP range only. Without this rule the instance has no SSH path from the
  # internet at all: access goes through `gcloud compute ssh
  # --tunnel-through-iap`.
  source_ranges = var.ssh_source_ranges

  depends_on = [google_project_service.required_apis]
}

# ------------------------------------------------------------
# 3. Instance
# ------------------------------------------------------------
locals {
  # The public key can be injected as a variable (CI) or read from the local
  # filesystem. `try()` keeps `terraform validate` working on machines that do
  # not have the key.
  ssh_public_key = var.ssh_public_key != null ? var.ssh_public_key : try(
    trimspace(file(pathexpand(var.ssh_public_key_path))), ""
  )

  # The only reason this project ever attaches an address: the VM needs egress
  # to run apt and docker pull. It opens no inbound port.
  has_external_ip = var.enable_egress
}

check "ssh_public_key_present" {
  assert {
    condition     = length(local.ssh_public_key) > 0
    error_message = <<-EOT
      No SSH public key was found.
      Set `ssh_public_key` or fix `ssh_public_key_path`
      (default: ~/.ssh/id_deploy_gcp.pub).
    EOT
  }
}

resource "google_service_account" "backup" {
  project      = var.project_id
  account_id   = var.backup_service_account_id
  display_name = "DevOps lab backups"

  # Never a key. The instance authenticates with this identity through the
  # instance metadata server, so there is no private key on the disk to steal,
  # rotate, or accidentally commit.
  depends_on = [google_project_service.required_apis]
}

resource "google_compute_instance" "vm" {
  name         = var.instance_name
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  # Prevents an accidental destroy caused by a typo in `terraform destroy`.
  deletion_protection       = var.deletion_protection
  allow_stopping_for_update = true

  labels = var.labels

  boot_disk {
    auto_delete = true

    initialize_params {
      image = var.image
      size  = var.disk_size_gb
      # pd-standard, not pd-balanced: it is the only disk class in the Always
      # Free tier, and the io-wait that used to justify pd-balanced came from
      # cAdvisor, not from the disk. Changing it forces a VM replacement.
      type = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    # No access_config means no external IP: the default free profile. IAP can
    # still forward SSH and TCP to a private instance, so nothing is lost
    # except public reachability.
    #
    # enable_egress attaches an ephemeral address (nat_ip = null) so apt and
    # docker can download during a deployment. It opens no inbound port and the
    # address disappears when the variable goes back to false.
    dynamic "access_config" {
      for_each = local.has_external_ip ? [1] : []

      content {
        nat_ip = null
      }
    }
  }

  # Access bootstrap: the public key is injected for the image default user.
  # From there on, Ansible owns the instance.
  metadata = {
    ssh-keys = "${var.ssh_user}:${local.ssh_public_key}"
    # Hardening (CKV_GCP_32): never fall back to project-wide SSH keys. The
    # instance is reachable only through IAP anyway, and the key below is the
    # sole bootstrap credential.
    block-project-ssh-keys = true
  }

  service_account {
    # A dedicated service account, never the default compute SA. The default one
    # is shared by every workload in the project, is frequently granted Editor,
    # and cannot have its keys disabled.
    email = google_service_account.backup.email

    # Scope stays cloud-platform because `gsutil cp` is not reliably happy on
    # narrower storage scopes. Authorisation is what limits this account: the SA
    # holds roles/storage.objectCreator on exactly one bucket and nothing else.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  scheduling {
    # STANDARD (the default): the VM can be stopped automatically instead of
    # being Terminated.
    provisioning_model  = "STANDARD"
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  tags = ["gcp-devops-lab", "ansible-managed"]

  # NOTE: only bootstrap metadata belongs here. System configuration (swap,
  # limits, cron, hardening) is applied by Ansible, not by Terraform.
  # `metadata_startup_script` is deliberately avoided: every change to it forces
  # a replacement of the instance (ForceNew).

  depends_on = [
    google_project_service.required_apis,
    google_compute_firewall.allow_ssh_iap,
  ]
}

# ------------------------------------------------------------
# 4. Disaster recovery
# ------------------------------------------------------------
# The database backup fits in the Always Free Cloud Storage allowance (5 GB,
# same region) and covers data corruption or accidental deletion. Whole-instance
# recovery is Terraform + Ansible plus restoring the database from the bucket.
#
# Snapshots are deliberately not part of this project: they are billed and were
# the only resource outside the free tier.
resource "google_storage_bucket" "backups" {
  count = var.backup_bucket_name == "" ? 0 : 1

  name                        = var.backup_bucket_name
  location                    = var.backup_bucket_location
  project                     = var.project_id
  force_destroy               = true
  uniform_bucket_level_access = true
  # Hardening (CKV_GCP_114): the backups are never public, and the instance only
  # gets objectCreator. Making the refusal explicit instead of relying on IAM.
  public_access_prevention = "enforced"

  labels = var.labels

  versioning {
    # Keeps a deleted or overwritten backup recoverable for 7 days.
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.backup_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 1
    }
    action {
      # Noncurrent versions are only kept by a backup mistake, never needed for
      # normal restores, so they expire quickly to bound the storage bill.
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_storage_bucket_iam_member" "backups_writer" {
  count = var.backup_bucket_name == "" ? 0 : 1

  bucket = google_storage_bucket.backups[0].name
  role   = "roles/storage.objectCreator"

  # References the account directly rather than
  # `google_compute_instance.vm.service_account[0].email`. The grant is about the
  # identity, not the machine: a forced VM replacement must not drag an IAM
  # binding into the same plan.
  member = "serviceAccount:${google_service_account.backup.email}"
}

# Deliberately objectCreator and not objectAdmin: the instance may create backup
# objects but must not be able to delete or read them. Expiry is handled by the
# lifecycle rules above, so the VM never needs delete permission, and a
# compromised instance cannot erase the history of backups.
#
# Restores are an operator action performed with the owner's credentials, not
# something the instance does on its own.
