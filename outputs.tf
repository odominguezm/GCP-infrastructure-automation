# ============================================================
# Outputs: consumed by the operator and by CI to reach the instance.
# ============================================================

locals {
  # How to actually get in: SSH is not exposed to the internet, it is proxied
  # by Identity-Aware Proxy. Reused by every tunnel command below.
  ssh_command = format(
    "gcloud compute ssh %s --tunnel-through-iap --zone %s --tunnel-iap",
    google_compute_instance.vm.name,
    var.zone,
  )
}

output "instance_name" {
  description = "Instance name."
  value       = google_compute_instance.vm.name
}

output "public_ip" {
  description = "Static public IP of the instance."
  value       = google_compute_address.static_ip.address
}

output "web_url" {
  description = "Public URL served by Nginx Proxy Manager."
  value       = "http://${google_compute_address.static_ip.address}"
}

output "ssh_command" {
  description = "Command to SSH into the instance through IAP."
  value       = local.ssh_command
}

# Admin ports are not published to the internet. To reach Grafana locally:
output "grafana_tunnel_command" {
  description = "Tunnel that exposes Grafana (port 3000) on localhost."
  value       = "${local.ssh_command} -L 3000:localhost:3000"
}

output "npm_admin_tunnel_command" {
  description = "Tunnel that exposes the Nginx Proxy Manager admin panel (port 81) on localhost."
  value       = "${local.ssh_command} -L 8081:localhost:81"
}

output "public_open_ports" {
  description = "Ports reachable from the internet."
  value       = ["80", "443"]
}