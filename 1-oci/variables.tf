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

variable "private_key_path" {
  description = "Path to private key to use for signing"
  type        = string
}

variable "public_key_path" {
  description = "Path to public key to use for signing"
  type        = string
}

variable "fingerprint" {
  description = "The fingerprint of the key to use for signing"
  type        = string
}

#if your private key has a password
#variable "private_key_password" {
#  description = "Password for private key to use for signing"
#  type        = string
#}

variable "my_public_ip_cidr" {
  description = "Your public IP, CIDR format x.x.x.x/32"
  type        = string
}

variable "os_image_id" {
  description = "OS Image ID to use"
  type        = string
}

variable "certmanager_email_address" {
  description = "Your email address for certification manager"
  type        = string
}

variable "k3s_server_pool_size" {
  default = 3
}
variable "k3s_worker_pool_size" {
  default = 0
}
