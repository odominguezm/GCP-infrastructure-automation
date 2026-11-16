# ============================================================
# Outputs: consumed by the operator and by CI to reach the instance.
# ============================================================

locals {
  # How to actually get in: SSH is never exposed to the internet, it is proxied
  # by Identity-Aware Proxy. Reused by every tunnel command below.
  ssh_command = format(
    "gcloud compute ssh %s --tunnel-through-iap --zone %s",
    google_compute_instance.vm.name,
    var.zone,
  )

  # Whatever address the VM actually has: an ephemeral one during an egress
  # window, or none in the default free profile.
  external_ip = try(google_compute_instance.vm.network_interface[0].access_config[0].nat_ip, null)
}

output "deployment_profile" {
  description = "Whether the VM currently has an ephemeral address for egress."
  value = (
    var.enable_egress
    ? "egress-window (ephemeral address for downloads, no inbound ports, address billed hourly)"
    : "free-tier (private, access only through IAP)"
  )
}

output "instance_name" {
  description = "Instance name."
  value       = google_compute_instance.vm.name
}

output "zone" {
  description = "Zone the instance lives in."
  value       = var.zone
}

output "ssh_user" {
  description = "Image default user used for the SSH key bootstrap."
  value       = var.ssh_user
}

output "internal_ip" {
  description = "Private IP of the instance. Reachable only from inside the VPC or through IAP."
  value       = google_compute_instance.vm.network_interface[0].network_ip
}

output "external_ip" {
  description = "Ephemeral address during an egress window, or null in the free profile."
  value       = local.external_ip
}

output "ssh_command" {
  description = "Command to SSH into the instance through IAP."
  value       = local.ssh_command
}

# The web stack is reached through this tunnel in every profile.
output "web_tunnel_command" {
  description = "Tunnel that exposes the Nginx Proxy Manager web endpoint on localhost:8080."
  value       = "${local.ssh_command} -L 8080:localhost:80"
}

output "grafana_tunnel_command" {
  description = "Tunnel that exposes Grafana (port 3000) on localhost."
  value       = "${local.ssh_command} -L 3000:localhost:3000"
}

output "prometheus_tunnel_command" {
  description = "Tunnel that exposes Prometheus (port 9090) on localhost."
  value       = "${local.ssh_command} -L 9090:localhost:9090"
}

output "npm_admin_tunnel_command" {
  description = "Tunnel that exposes the Nginx Proxy Manager admin panel (port 81) on localhost."
  value       = "${local.ssh_command} -L 8081:localhost:81"
}

output "backup_bucket_name" {
  description = "Cloud Storage bucket for off-site database backups. Empty when disabled."
  value       = var.backup_bucket_name
}
