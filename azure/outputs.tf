output "ip_publico" {
  value = azurerm_public_ip.frota.ip_address
}

output "fqdn" {
  value = azurerm_public_ip.frota.fqdn
}

output "ssh" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.frota.ip_address}"
}

output "api_url" {
  value = "http://${azurerm_public_ip.frota.ip_address}/api/telemetry"
}

output "grafana_url" {
  value = "http://${azurerm_public_ip.frota.ip_address}:3000"
}

output "redpanda_console_tunel" {
  description = "Redpanda Console não é exposto: acesse por túnel SSH e abra http://localhost:8088."
  value       = "ssh -L 8088:localhost:8088 ${var.admin_username}@${azurerm_public_ip.frota.ip_address}"
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}
