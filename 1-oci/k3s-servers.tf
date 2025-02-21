resource "oci_core_instance_pool" "k3s_servers" {
  depends_on = [
    oci_identity_dynamic_group.compute_dynamic_group,
    oci_identity_policy.compute_dynamic_group_policy
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [load_balancers, freeform_tags, instance_configuration_id]
  }

  display_name              = "k3s-servers"
  compartment_id            = var.compartment_ocid
  instance_configuration_id = oci_core_instance_configuration.k3s_server_template.id

  placement_configurations {
    availability_domain = var.availability_domain
    primary_subnet_id   = oci_core_subnet.default_oci_core_subnet10.id
    fault_domains       = var.fault_domains
  }

  size = var.k3s_server_pool_size

  freeform_tags = {
    "provisioner"           = "terraform"
    "environment"           = "${var.environment}"
    "${var.unique_tag_key}" = "${var.unique_tag_value}"
    "k3s-cluster-name"      = "${var.cluster_name}"
    "k3s-instance-type"     = "k3s-server"
  }
}

resource "oci_core_instance" "k3s_extra_server_node" {
  count = var.k3s_extra_server_node ? 1 : 0
  depends_on = [
    oci_identity_dynamic_group.compute_dynamic_group,
    oci_identity_policy.compute_dynamic_group_policy,
    oci_core_instance_pool.k3s_servers
  ]

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "K3s extra server node"

  agent_config {
    is_management_disabled = "false"
    is_monitoring_disabled = "false"

    plugins_config {
      desired_state = "DISABLED"
      name          = "Vulnerability Scanning"
    }

    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }

    plugins_config {
      desired_state = "DISABLED"
      name          = "Bastion"
    }
  }

  shape = var.compute_shape
  shape_config {
    memory_in_gbs = "6"
    ocpus         = "1"
  }

  source_details {
    source_id   = var.os_image_id
    source_type = "image"
  }

  create_vnic_details {
    assign_public_ip          = true
    subnet_id                 = oci_core_subnet.default_oci_core_subnet10.id
    nsg_ids                   = [oci_core_network_security_group.lb_to_instances_kubeapi.id]
    hostname_label            = "k3s-extra-server-node"
  }

  metadata = {
    "ssh_authorized_keys" = file(var.public_key_path)
    "user_data"           = data.cloudinit_config.k3s_server_tpl.rendered
  }

  freeform_tags = {
    "provisioner"           = "terraform"
    "environment"           = "${var.environment}"
    "${var.unique_tag_key}" = "${var.unique_tag_value}"
    "k3s-cluster-name"      = "${var.cluster_name}"
    "k3s-instance-type"     = "k3s-server"
  }
}