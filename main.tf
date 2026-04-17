terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  #credentials = file("keys/gcp-auth.json")
  project     = "devops-lab-orlando"
  region      = "us-central1"
  zone        = "us-central1-a"
}

# 1. Red Virtual (VPC)
resource "google_compute_network" "vpc_devops" {
  name                    = "vpc-devops-lab"
  auto_create_subnetworks = false
}

# 2. Subred
resource "google_compute_subnetwork" "subnet_devops" {
  name          = "subnet-devops"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.vpc_devops.id
}

# 3. Regla de Firewall para SSH
resource "google_compute_firewall" "ssh_rule" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_devops.name

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"] # Permitir SSH, HTTP y HTTPS
  }

  source_ranges = ["0.0.0.0/0"]
}

# 4. Instancia Always Free (e2-micro)
resource "google_compute_instance" "vm_devops" {
  name         = "instancia-devops-gcp"
  machine_type = "e2-micro" # Capa gratuita de por vida en us-central1

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 30 # 30GB es el límite gratuito
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet_devops.id
    access_config {
      # Esto genera la IP Pública
    }
  }

  metadata = {
    # Usamos la nueva llave generada
    ssh-keys = "orlando_dominguezm:${file("~/.ssh/id_rsa_gcp.pub")}"
  }
}

# Output para obtener la IP al terminar
output "ip_publica" {
  value = google_compute_instance.vm_devops.network_interface[0].access_config[0].nat_ip
}

