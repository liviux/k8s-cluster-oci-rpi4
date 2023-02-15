module "k3s_cluster" {
  source                    = "github.com/garutilorenzo/k3s-oci-cluster"
  region                    = var.region
  availability_domain       = var.availability_domain
  tenancy_ocid              = var.tenancy_ocid
  compartment_ocid          = var.compartment_ocid
  my_public_ip_cidr         = var.my_public_ip_cidr
  public_key_path           = var.public_key_path
  cluster_name              = "k3s_cluster"
  environment               = "production"
  os_image_id               = var.os_image_id
  certmanager_email_address = var.certmanager_email_address
  ingress_controller        = "default"
  install_longhorn          = false
  install_argocd            = false
  k3s_server_pool_size      = var.k3s_server_pool_size
  k3s_worker_pool_size      = var.k3s_worker_pool_size
}

output "k3s_servers_ips" {
  value = module.k3s_cluster.k3s_servers_ips
}

output "k3s_workers_ips" {
  value = module.k3s_cluster.k3s_workers_ips
}

output "public_lb_ip" {
  value = module.k3s_cluster.public_lb_ip
}