output "k3s_servers_ips" {
  description = "Public IP addresses of K3s server nodes"
  depends_on = [
    data.oci_core_instance_pool_instances.k3s_servers_instances,
  ]
  value = data.oci_core_instance.k3s_servers_instances_ips.*.public_ip
}

output "k3s_workers_ips" {
  description = "Public IP addresses of K3s worker nodes"
  depends_on = [
    data.oci_core_instance_pool_instances.k3s_workers_instances,
  ]
  value = data.oci_core_instance.k3s_workers_instances_ips.*.public_ip
}

output "public_lb_ip" {
  description = "IP addresses of the public network load balancer"
  value = oci_network_load_balancer_network_load_balancer.k3s_public_lb.ip_addresses
}

output "k3s_extra_server_ip" {
  description = "Public IP address of the extra K3s server node (if enabled)"
  value = var.k3s_extra_server_node ? oci_core_instance.k3s_extra_server_node[0].public_ip : null
}

output "cluster_endpoint" {
  description = "The endpoint for your K3s cluster"
  value       = "https://${local.public_lb_ip[0]}:${var.kube_api_port}"
  sensitive   = true
}
