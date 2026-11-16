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

  # The reserved address only exists in the public demo profile. `one()` returns
  # null instead of indexing a zero-count resource.
  public_ip = one(google_compute_address.static_ip[*].address)

  # Whatever address the VM actually has: the reserved one, an ephemeral one
  # during an egress window, or none in the free profile.
  external_ip = try(google_compute_instance.vm.network_interface[0].access_config[0].nat_ip, null)
}

output "deployment_profile" {
  description = "Free profile, egress window or public demo: what is billed and what is reachable."
  value = (
    var.enable_public_ip
    ? "public-ip (static address, 80/443 open, address billed hourly)"
    : var.enable_egress
    ? "egress-window (ephemeral address for downloads, no inbound ports, address billed hourly)"
    : "free-tier (private, access only through IAP)"
  )
}

output "instance_name" {
  description = "Instance name."
  value       = google_compute_instance.vm.name
}

output "internal_ip" {
  description = "Private IP of the instance. Reachable only from inside the VPC or through IAP."
  value       = google_compute_instance.vm.network_interface[0].network_ip
}

output "public_ip" {
  description = "Reserved static public IP of the public demo profile, or null otherwise."
  value       = local.public_ip
}

output "external_ip" {
  description = "Address the VM actually has: static, ephemeral during an egress window, or null in the free profile."
  value       = local.external_ip
}

output "web_url" {
  description = "Public URL served by Nginx Proxy Manager, or null in the free profile."
  value       = local.public_ip == null ? null : "http://${local.public_ip}"
}

output "ssh_command" {
  description = "Command to SSH into the instance through IAP."
  value       = local.ssh_command
}

# In the default free profile the web stack is reached through this tunnel.
output "web_tunnel_command" {
  description = "Tunnel that exposes the Nginx Proxy Manager web endpoint on localhost:8080."
  value       = "${local.ssh_command} -L 8080:localhost:80"
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
  description = "Ports reachable from the internet. Empty in the default free profile."
  value       = var.enable_public_ip ? ["80", "443"] : []
}

output "backup_bucket_name" {
  description = "Cloud Storage bucket for off-site database backups. Empty when disabled."
  value       = var.backup_bucket_name
}
