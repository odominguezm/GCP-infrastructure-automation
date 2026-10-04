# ============================================================
# Terraform - GCP Single-Instance DevOps Lab
#
# Owns the network and the instance. The configuration of the
# services running inside the VM is handled by Ansible (see site.yml).
# ============================================================

terraform {
  required_version = ">= 1.5.0"

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
# 2. Static public IP
# ------------------------------------------------------------
# Reserving the address as a resource (instead of clicking through the console)
# is part of IaC: the address lives in Terraform state and survives the
# destruction and recreation of the VM.
#
# NOTE: to adopt an address that was already reserved by hand (in this project
# 34.60.225.223, named "lab"), rename it first and then import it. Otherwise
# Terraform reserves a brand new IP:
#   gcloud compute addresses set-address lab \
#     --new-address=instancia-devops-gcp-ip --region=us-central1 --project=devops-lab-orlando
#   terraform import google_compute_address.static_ip \
#     devops-lab-orlando/us-central1/instancia-devops-gcp-ip
resource "google_compute_address" "static_ip" {
  name   = var.static_address_name
  region = var.region

  depends_on = [google_project_service.required_apis]
}

# ------------------------------------------------------------
# 3. Firewall
# ------------------------------------------------------------
# Exposure policy:
#   - 80/443  public: the only thing that has to be reachable from the internet,
#             and it is served by Nginx Proxy Manager.
#   - 22      restricted to the IAP range (35.235.240.0/20).
#   - 81/3000/9090/21680 (NPM admin, Grafana, Prometheus, demo app) are NOT
#             opened to the world. They are reached through an SSH tunnel over
#             IAP:
#     gcloud compute ssh <instance> --tunnel-through-iap --zone <zone> \
#       -L 3000:localhost:3000
resource "google_compute_firewall" "allow_web" {
  name        = "${var.network_name}-allow-web"
  description = "Public HTTP/HTTPS served by Nginx Proxy Manager."
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.web_source_ranges

  depends_on = [google_project_service.required_apis]
}

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
# 4. Instance
# ------------------------------------------------------------
locals {
  # The public key can be injected as a variable (CI) or read from the local
  # filesystem. `try()` keeps `terraform validate` working on machines that do
  # not have the key.
  ssh_public_key = var.ssh_public_key != null ? var.ssh_public_key : try(
    trimspace(file(pathexpand(var.ssh_public_key_path))), ""
  )
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

  # Shielded VM: vTPM + Secure Boot + integrity monitoring.
  # Requires the project organisation policy to allow it.
  dynamic "shielded_instance_config" {
    for_each = var.enable_shielded_vm ? [1] : []

    content {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image = var.image
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  # Access bootstrap: the public key is injected for the image default user.
  # From there on, Ansible owns the instance.
  metadata = {
    ssh-keys = "${var.ssh_user}:${local.ssh_public_key}"
  }

  service_account {
    # A dedicated service account, never the default compute SA.
    #
    # The default compute SA is shared by every workload in the project, is
    # frequently granted Editor by organisation policy, and cannot have its keys
    # disabled. A compromise of this instance would then start from an account
    # with far more reach than the backups need, and revoking it later would
    # break every other instance at once.
    email = google_service_account.backup.email

    # Scope stays cloud-platform because `gsutil -m cp` (used by the backup
    # script) is not reliably happy on narrower storage scopes, and a failure
    # there is only logged as a warning: too-narrow a scope would turn into a
    # silently broken disaster recovery path.
    #
    # The scope is not what limits this account. Authorisation is: the SA holds
    # roles/storage.objectCreator on exactly one bucket and nothing else in the
    # project, so the token it receives cannot do anything the IAM policy does
    # not allow, whatever the scope says. Tightening the scope to
    # devstorage.* is still worth doing, but only together with a test that
    # proves the upload works, which needs the boot disk recreated (see
    # docs/runbooks/disaster-recovery.md).
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  scheduling {
    # STANDARD (the default): the VM can be stopped automatically instead of
    # being Terminated. Essential on an e2-micro with 1 GB of RAM, where an idle
    # instance is most of the day.
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
# ============================================================
# Disaster recovery
#
# Until this existed, "disaster recovery" was a single line in the README
# pointing at a cron job that copied a SQLite file to the same disk it was
# already on. That is not a backup: a lost disk, a mistaken `rm`, or a bad
# upgrade destroys both the database and the copy at the same instant.
#
# Two independent layers, because they cover different failures:
#
#   1. Database backups in Cloud Storage. Small, fast, restorable in minutes.
#      Covers data corruption and accidental deletion.
#   2. Disk snapshots. Everything, including Docker volumes and /etc. Covers
#      the failure where the instance itself is unrecoverable.
# ============================================================

resource "google_storage_bucket" "backups" {
  count = var.backup_bucket_name == "" ? 0 : 1

  name                        = var.backup_bucket_name
  location                    = var.backup_bucket_location
  project                     = var.project_id
  force_destroy               = true
  uniform_bucket_level_access = true

  labels = var.labels

  versioning {
    # Keeps a deleted or overwritten backup recoverable for 7 days. Without it,
    # a mistake in the upload path is as irreversible as deleting the file.
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
  # `google_compute_instance.vm.service_account[0].email`.
  #
  # Reading the email off the instance made the bucket grant depend on the
  # instance resource, which means any forced replacement of the VM (a boot disk
  # type change, an image family bump) drags an IAM binding into the same plan.
  # The grant is about the identity, not the machine, so it should stand alone.
  member = "serviceAccount:${google_service_account.backup.email}"
}

# Deliberately objectCreator and not objectAdmin: the instance may create backup
# objects but must not be able to delete or read them. Expiry is handled by the
# lifecycle rules above, so the VM never needs delete permission, and a
# compromised instance cannot erase the history of backups.
#
# Restores are an operator action performed with the owner's credentials, not
# something the instance does on its own.

# NOTE on the resource name: in provider 6.x this is `google_compute_resource_policy`.
# It used to be `google_compute_snapshot_schedule_policy`, which was renamed when
# snapshot schedules became one instance of a wider concept. Following the old
# name fails validation with "provider does not support resource type".

resource "google_compute_resource_policy" "daily_snapshot" {
  count = var.enable_snapshots ? 1 : 0

  name        = "devops-daily-snapshot"
  project     = var.project_id
  description = "Daily snapshot of the boot disk, for full-instance recovery."
  region      = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        # The API only accepts 00:00, 04:00, 08:00, 12:00, 16:00 or 20:00 UTC.
        # 04:00 is chosen because it is the first allowed slot after the 03:00
        # database backup, so the snapshot and the database dump do not compete
        # for the same 1 GB of RAM and the same disk I/O at the same moment.
        start_time    = "04:00"
        days_in_cycle = 1
      }
    }

    retention_policy {
      # KEEP_AUTO_SNAPSHOTS rather than APPLY_RETENTION_POLICY: if the disk is
      # deleted, the snapshots survive. That is the entire point of having them.
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_compute_disk_resource_policy_attachment" "snapshot_schedule" {
  count = var.enable_snapshots ? 1 : 0

  project = var.project_id
  # Both arguments are disk names. The boot disk is created inline in the
  # instance block, so it is addressed by the instance name: an instance-managed
  # boot disk carries the same name as its instance.
  #
  # `var.instance_name` instead of `google_compute_instance.vm.name`: the value
  # is identical, but reading it off the instance resource made the attachment
  # depend on the whole instance. That dragged a scheduled-backup change into
  # the same plan as the boot disk type, and the disk type forces a replacement
  # - so enabling snapshots would have implied rebuilding the machine.
  name = google_compute_resource_policy.daily_snapshot[0].name
  disk = var.instance_name
  zone = var.zone
}
