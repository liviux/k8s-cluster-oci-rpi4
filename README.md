# Kubernetes cluster with OCI free-tier and Raspberry Pi4
This long read is a tutorial for deploying a Kubernetes (using k3s) cluster with 4 x OCI free-tier ARM instances and 4 x Raspberry Pi 4 (or how many do you have). Plus some applications needed for installation (Terraform, Ansible, ) and a lot of things installed on the cluster (Prometheus, Grafana, ).
I've made a series of articles on [dev.to](https://dev.to/liviux/k8s-cluster-with-oci-free-tier-and-raspberry-pi4-part-1) for this repo.


# Table of Contents

- [Kubernetes cluster with OCI free-tier and Raspberry Pi4](#kubernetes-cluster-with-oci-free-tier-and-raspberry-pi4)
- [Table of Contents](#table-of-contents)
    - [OCI](#oci)
      - [Requirements](#requirements)
      - [Preparing](#preparing)
      - [Provisioning](#provisioning)
    - [Raspberry Pi4](raspberry-pi4)
      - [Requirements](#requirements)
      - [Preparing](#preparing)
      - [Provisioning](#provisioning)
  - [References](#references)

# OCI

This section is for the OCI part of the cluster.

## Requirements

- Obvious, an OCI account, get it from here - [oracle.com/cloud](https://www.oracle.com/cloud/). If you already have an account, be careful not to have any resources provisioned already (even for other users, or compartments), this tutorial will use all free-tier ones;
- I used Windows 11 with WSL2 running Ubuntu 20.04, but this will work on any Linux machine;
- Terraform installed (tested with v1.3.7 - and OCI provider v4.105)- how to [here](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli);

## Preparing

_(following official guidelines from [Oracle](https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm))_


For safety we should use a separate compartment and user for our OCI configuration, not root ones. Now is a good time to create a new notes file and add some values there, you will need them later. Mostly you will add 3 things for each value (user + user_name_you_created + it's_OCID; group  ... etc.).
Go to **Identity & Security > Compartments** and click on **Create Compartment**. Open it and copy the **OCID** to your notes file. Then in **Identity & Security > Users** click on **Create User**. Open it and copy the **OCID** to your notes file.
Then in **Identity & Security > Groups** click on **Create Group**. The same as above with the **OCID**. Here click on **Add User to Group** and add the newly created user.
In **Identity & Security > Policies** click on **Create Policy**, **Show manual editor** and add the following 

```
allow group group_you_created to read all-resources in <compartment compartment_you_created>
allow group group_you_created to manage virtual-network-family  in compartment <compartment_you_created>
allow group group_you_created to manage instance-family  in compartment <compartment_you_created>
allow group group_you_created to manage compute-management-family  in compartment <compartment_you_created>
allow group group_you_created to manage volume-family  in compartment <compartment_you_created>
allow group group_you_created to manage load-balancers  in compartment <compartment_you_created>
allow group group_you_created to manage network-load-balancers  in compartment <compartment_you_created>
allow group group_you_created to manage dynamic-groups in compartment <compartment_you_created>
allow group group_you_created to manage policies in compartment <compartment_you_created>
allow group group_you_created to manage dynamic-groups in tenancy
```


Then you need access to OCI from your machine. So, create a new folder in HOME directory
`mkdir ~/.oci`
Generate a private key there
`openssl genrsa -out ~/.oci/key.pem 2048`
Change permissions for it
`chmod 600 ~/.oci/key.pem`
Then generate you're public key
`openssl rsa -pubout -in ~/.oci/key.pem -out $HOME/.oci/key_public.pem`
And then copy that public key, everything inside that file 
`cat ~/.oci/key_public.pem`
This key has to be added to your OCI new user. Go to **OCI > Identity & Security > Users** select the new user and open **API Keys** , click on **Add API Key**, select **Paste Public Key**, and there paste all your copied key.
After you've done that you need to copy to notes the fingerprint too. Save the path to the private key too.
_*note: Use ~ and not $HOME, that's the only way it worked for me._

To your notes file copy the following too:
- Tenancy **OCID**. Click on your avatar (from top-right), and select **Tenancy**.
- Region. In the top right there is the name of your region too. Now find it [here](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm) and copy it's identifier (ex. eu-paris-1).
- The path to the private key. In our case - `~/.oci/key.pem`

Now create a new folder to test if terraform is ok and linked with OCI. In that folder create a file **main.tf** and add this:
```
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "4.105.0"
    }
  }
}


# Configure the OCI provider with an API Key

provider "oci" {
  tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaYOURTENANCY3uzx4a"
  user_ocid        = "ocid1.user.oc1..aaaaaaYOURUSER4s5ga"
  private_key_path = "~/.oci/oci.pem"
  fingerprint      = "2a:d8:YOURFINGERPRINT:a1:cd:06"
  region           = "eu-YOURREGION"
}

#Get a list of Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = "ocid1.tenancy.oc1..aaaaaaYOURTENANCYuzx4a"
}

#Output the result
output "all-availability-domains-in-your-compartment" {
  value = data.oci_identity_availability_domains.ads.availability_domains
}
```
Now you should run `terraform init` to download the OCI provider and then `terraform plan` to see what will happen and `terraform apply` to receive final results. This small demo configuration file from above should return the name of the availability domains in that regions. If you receive something like **"name" = "pmkj:EU-YOURREGION-1-AD-1"** and no errors then everything is ok until now. This file can be deleted now.

## Provisioning

You will need to add some new values to the notes file:
- From inside OCI, on top right corner, click on **Developer Tools > Cloud Shell** and there write `oci iam availability-domain list`. Save the name, not id (if more than 1, pick one). This is your _availability_domain_ variable;
- Again from this console type `oci compute image list --compartment-id <YOUR-COMPARTMENT> --operating-system "Canonical Ubuntu" --operating-system-version "22.04 Minimal aarch64" --shape "VM.Standard.A1.Flex"`, to find the OS Image ID. Probably the first result has the latest build, in my case was _Canonical-Ubuntu-22.04-Minimal-aarch64-2022.11.05-0_. From here save the id. This is your _os_image_id_ variable;
- Now just google "_my ip_" and you will find your Public IP. Save it in CIDR format, ex. _111.222.111.99/32_. This is your _my_public_ip_cidr_ variable. If you don't have a static IPv4 form your ISP, i don't know a quick solution for you, maybe someone can comment one. You can setup DDNS, but that can't be used in Security List afaik. Only solution every time your IP changes, go to **VCN >  Security List** and modify the **Ingress rule** with the new IP;
- Your _public_key_path_ is your public SSH keys. If you don't have any, quickly generate them with `ssh-keygen`. You should have one now in _~/.ssh/key.pub_;
- Last is your email address that will be used to install a certification manager. That will be your _certmanager_email_address_ variable. I didn't setup one, as this is just a personal project for testing.

After you've cloned the repo, go to oci/terraform.tfvars and edit all values with the ones from your notes file. 
This build uses the great terraform configuration files from this repo of [garutilorenzo](https://github.com/garutilorenzo/k3s-oci-cluster) (using version 2.2; if you have errors running all of this, you should check what changed in this repo since v2.2, or 01.02.23). You can read [here](https://github.com/garutilorenzo/k3s-oci-cluster#pre-flight-checklist) if you want to customize your configuration and edit the _main.tf_ file. This is the diagram that garutilorenzo made and how your deployment will look like (this tutorial is without Longhorn and with ingress controller set as Traefik):
![diagram](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/j55a7depvbo0yz0n03tp.png)  
_*note_ - I've got some problems with clock of WSL2 not being synced to Windows clock. And provisioning didn't worked so if you receive clock errors too, verify your time with `date `command, if out of sync just run `sudo hwclock -s`.
Now just run `terraform plan` and then `terraform apply`. If everything was ok you should have your resources created.

When the script finishes save the outputs (or you can find the values in OCI):
```
Outputs:
k3s_servers_ips = [
  "152.x.x.115",
]
k3s_workers_ips = [
  "140.x.x.158",
  "140.x.x.226",
]
public_lb_ip = tolist([
  {
    "ip_address" = "140.x.x.159"
    "ip_version" = "IPV4"
    "is_public" = true
    "reserved_ip" = tolist([])
  },
  {
    "ip_address" = "10.0.1.96"
    "ip_version" = "IPV4"
    "is_public" = false
    "reserved_ip" = tolist([])
```
Now you can connect to any worker or server IP using `ssh -i ~/.ssh/key ubuntu@152.x.x.115`. Connect to server IP and write `sudo kubectl get nodes` to check all nodes.

# Raspberry Pi4

This section is for the RPI4 part of the cluster.

# References
Official OCI provider documentation from Terraform - [here](https://registry.terraform.io/providers/oracle/oci/latest/docs).  
Official OCI Oracle documentation with Tutorials - [here](https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm) and Guides - [here](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraform.htm).  
Great GitHub repo of garutilorenzo - [here](https://github.com/garutilorenzo/k3s-oci-cluster). There are a few others who can help you with k8s on OCI too [1](https://arnoldgalovics.com/free-kubernetes-oracle-cloud/) with [repo](https://github.com/galovics/free-kubernetes-oracle-cloud-terraform), [2](https://github.com/r0b2g1t/k3s-cluster-on-oracle-cloud-infrastructure), [3](https://github.com/solamarpreet/kubernetes-on-oci).  
