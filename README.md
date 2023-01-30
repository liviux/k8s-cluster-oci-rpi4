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
