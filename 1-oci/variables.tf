# Authentication and Basic Settings
variable "tenancy_ocid" {
  description = "The tenancy OCID"
  type        = string
}

variable "compartment_ocid" {
  type        = string
  description = "The compartment to create the resources in - OCID of it"
}

variable "user_ocid" {
  description = "The user OCID."
  type        = string
}

variable "region" {
  type        = string
  description = "The region to provision the resources in"
}

variable "availability_domain" {
  type        = string
  description = "The availability domain to provision the resources in"
}

variable "fingerprint" {
  description = "The fingerprint of the key to use for signing"
  type        = string
}

# SSH Keys
variable "private_key_path" {
  description = "Path to private key to use for signing"
  type        = string
}

variable "public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to your public workstation SSH key"
}

# Cluster Configuration
variable "environment" {
  type        = string
  description = "Environment name"
}

variable "cluster_name" {
  type        = string
  description = "Name of the K3s cluster"
}

variable "k3s_version" {
  type    = string
  default = "latest"
}

variable "k3s_server_pool_size" {
  type        = number
  description = "Number of server nodes in the K3s cluster"
}

variable "k3s_worker_pool_size" {
  type        = number
  description = "Number of worker nodes in the K3s cluster"
}

variable "k3s_extra_server_node" {
  type        = bool
  default     = true
  description = "Deploy an extra server node if true"
}

# Compute Configuration
variable "os_image_id" {
  description = "OS Image ID to use"
  type        = string
}

variable "compute_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "fault_domains" {
  type    = list(any)
  default = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
}

# Network Configuration
variable "my_public_ip_cidr" {
  description = "Your public IP, CIDR format x.x.x.x/32"
  type        = string
}

variable "oci_core_vcn_dns_label" {
  type    = string
  default = "defaultvcn"
}

variable "oci_core_subnet_dns_label10" {
  type    = string
  default = "defaultsubnet10"
}

variable "oci_core_subnet_dns_label11" {
  type    = string
  default = "defaultsubnet11"
}

variable "oci_core_vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "oci_core_subnet_cidr10" {
  type    = string
  default = "10.0.0.0/24"
}

variable "oci_core_subnet_cidr11" {
  type    = string
  default = "10.0.1.0/24"
}

# Load Balancer Configuration
variable "public_lb_shape" {
  type    = string
  default = "flexible"
}

variable "k3s_load_balancer_name" {
  type    = string
  default = "k3s internal load balancer"
}

variable "public_load_balancer_name" {
  type    = string
  default = "K3s public LB"
}

variable "kube_api_port" {
  type    = number
  default = 6443
}

variable "http_lb_port" {
  type    = number
  default = 80
}

variable "https_lb_port" {
  type    = number
  default = 443
}

# Ingress Configuration
variable "ingress_controller_http_nodeport" {
  type    = number
  default = 30080
}

variable "ingress_controller_https_nodeport" {
  type    = number
  default = 30443
}

# Add-ons Configuration
variable "certmanager_release" {
  type        = string
  description = "Version of cert-manager to install"
}

variable "certmanager_email_address" {
  type        = string
  description = "Your email address for certification manager"
}

variable "longhorn_release" {
  type        = string
  description = "Version of Longhorn to install"
}

variable "argocd_release" {
  type        = string
  description = "Version of ArgoCD to install"
}

variable "argocd_image_updater_release" {
  type        = string
  description = "Version of ArgoCD Image Updater to install"
}

variable "traefik_release" {
  type        = string
  description = "Version of Traefik to install"
}
  
variable "helm_version" {
  type        = string
  description = "Version of Helm to install"
}

variable "expose_kubeapi" {
  type    = bool
  default = false
}

# Tagging
variable "unique_tag_key" {
  type    = string
  default = "k3s-provisioner"
}

variable "unique_tag_value" {
  type    = string
  default = "https://github.com/liviux/k8s-cluster-oci-rpi4"
}

# IAM Configuration
variable "oci_identity_dynamic_group_name" {
  type        = string
  default     = "Compute_Dynamic_Group"
  description = "Dynamic group which contains all instance in this compartment"
}

variable "oci_identity_policy_name" {
  type        = string
  default     = "Compute_To_Oci_Api_Policy"
  description = "Policy to allow dynamic group, to read OCI api without auth"
}