# Kubernetes cluster with OCI free-tier and Raspberry Pi4
This long read is a tutorial for deploying a Kubernetes (using k3s) cluster with 4 x OCI free-tier ARM instances and 4 x Raspberry Pi 4 (or how many do you have). Plus some applications needed for installation (Terraform, Ansible, ) and a lot of things installed on the cluster (Prometheus, Grafana, ).


# Table of Contents

* [Important notes](#important-notes)
* [Requirements](#requirements)
* [Supported OS](#supported-os)
* [Example RSA key generation](#example-rsa-key-generation)
* [Project setup](#project-setup)
* [Oracle provider setup](#oracle-provider-setup)
* [Pre flight checklist](#pre-flight-checklist)
* [Notes about OCI always free resources](#notes-about-oci-always-free-resources)
* [Notes about K3s](#notes-about-k3s)
* [Infrastructure overview](#infrastructure-overview)
* [Cluster resource deployed](#cluster-resource-deployed)
* [Deploy](#deploy)
* [Deploy a sample stack](#deploy-a-sample-stack)
* [Clean up](#clean-up)
* [Known Bugs](#known-bugs)
* [References](#references)



# References
Official OCI provider documentation from Terraform - [here](https://registry.terraform.io/providers/oracle/oci/latest/docs).  
Official OCI Oracle documentation with Tutorials - [here](https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm) and Guides - [here](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraform.htm).  
Great GitHub repo of garutilorenzo - [here](https://github.com/garutilorenzo/k3s-oci-cluster). There are a few others who can help you with k8s on OCI too [1](https://arnoldgalovics.com/free-kubernetes-oracle-cloud/) with [repo](https://github.com/galovics/free-kubernetes-oracle-cloud-terraform), [2](https://github.com/r0b2g1t/k3s-cluster-on-oracle-cloud-infrastructure), [3](https://github.com/solamarpreet/kubernetes-on-oci).  
