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
    - [Raspberry Pi4](#raspberry-pi4)
      - [Requirements](#requirements-1)
      - [Preparing](#preparing-1)
      - [Ansible](#ansible)
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

## Requirements

- At least 2 Raspberry Pi. I've got 4 of them, 3 with 4GB and 1 with 8GB (that will be my master node). Every one needs a SD Card, a power adapter plus network cables (plus an optional switch and 4 cases);
- And the same from part 1. Windows 11 with WSL2 running Ubuntu 20.04, but this will work on any Linux & Win machine and Terraform installed (tested with v1.3.7)- how to [here](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli);


![my setup](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/0edbmj9h7vt1ls8805nd.jpg)My Pis


## Preparing

Installing an OS on Pi is very easy. Just insert the SD card in your PC and use Imager from [official website](https://www.raspberrypi.com/software/). I choose the same OS as in the OCI cluster, that is Ubuntu Server 22.04.1 64bit. In advanced settings (bottom right of Imager) pick _Set Hostname_ and write your own. I have rpi4-1 rpi4-2 rpi4-3 and rpi4-4. Pick _Enable SSH_ and _Set username and password_, this way you can connect to Pi immediately, without a monitor and keyboard for it. Then hit _Write_ and repeat this step for every one.

From my home router I found the devices IPs. Still there you can configure _Address reservation_ so every time they keep their IP. Did some Port forwarding too so I can access them from everywhere using DDNS from my ISP, as I don't have static IPv4. All of these settings are configured from you home router so Google how to if you're interested.

I added every PI to local machine _C:\Windows\System32\drivers\etc\hosts_  file to be able to control them easier.
```
192.168.0.201 rpi4-1
192.168.0.202 rpi4-2
192.168.0.203 rpi4-3
192.168.0.204 rpi4-4
```
We can check if everything is ok by running some `ping rpi4-1` or `ssh user@rpi4-1`.

## Ansible
For configuration management I picked Ansible as it is agentless and not so difficult (spoiler alert, it is though). We can control all RPI4 from local machine. Install Ansible first `sudo apt install ansible`.
Now from your PC run the following commands (assuming you already generated ssh keys from Part 1, using ssh-keygen):
```
ssh-copy-id -i ~/.ssh/key.pub user@rpi4-1
ssh-copy-id -i ~/.ssh/key.pub user@rpi4-2
ssh-copy-id -i ~/.ssh/key.pub user@rpi4-3
ssh-copy-id -i ~/.ssh/key.pub user@rpi4-4
```
This will allow Ansible to connect to every Pi without requesting the password every time. 
I had to uncomment with `sudo vi /etc/ansible/ansible.cfg` the line with `private_key_file = ~/.ssh/key`. And in /etc/ansible/hosts i added the following:
```
[server]
rpi4-1  ansible_connection=ssh

[agents]
rpi4-2  ansible_connection=ssh
rpi4-3  ansible_connection=ssh
rpi4-4  ansible_connection=ssh

[home:children]
server
agents
```
This will add the master rpi4 in a server group and the rest of workers to an agents group. Plus a bigger group having them all. My PC user and RPIs user is the same, but if you have a different one you have to add this to the same file:
```
[all:vars]
remote_user = user
```
Now test if everything is ok with `ansible home -m ping`. Green is ok.
I like to keep all my systems updated to latest version, especially this one used for testing. So we'll need to create a new file _update.yml_ and paste below block in it:
```
---
- hosts: home
  tasks:
    - name: Update apt repo and cache
      apt: update_cache=yes force_apt_get=yes cache_valid_time=3600
    - name: Upgrade all packages
      apt: upgrade=yes force_apt_get=yes
    - name: Check if a reboot is needed
      register: reboot_required_file
      stat: path=/var/run/reboot-required get_md5=no
    - name: Reboot the box if kernel updated
      reboot:
        msg: "Reboot initiated by Ansible for kernel updates"
        connect_timeout: 5
        reboot_timeout: 90
        pre_reboot_delay: 0
        post_reboot_delay: 30
        test_command: uptime
      when: reboot_required_file.stat.exists
```
This is an Ansible playbook that updates Ubuntu and then reboots the PIs. Now save it and run `ansible-playbook update.yml -K -b` which will ask for sudo password and run the playbook. It lasted ~10 minutes for me. On another shell you can ssh to any of the PIs and run `htop `to see the activity.
Now try `ansible home -a "rpi-eeprom-update -a" -b -K ` to see if there's any firmware update for you Raspberry Pi 4.
Next step is to enable cgroups on every PI. Create a new playbook append-cmd.yml and add:
```
---
- hosts: home
  tasks:
  - name: Append cgroup to cmdline.txt
    lineinfile:
      path: /boot/firmware/cmdline.txt
      backrefs: yes
      regexp: "^(.*)$"
      line: '\1 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1'
...
```
This will append to end of file _/boot/firmware/cmdline.txt_ the strings _cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1_. Run it with `ansible-playbook append-cmd.yml -K -b`.
I won't add a graphical interface and won't use Wi-Fi and Bluetooth so we can steal some memory from GPU memory, Wi-Fi and BT to be available to the Kubernetes cluster. So we need to add a few lines to _/boot/firmware/config.txt_ using a new Ansible playbook append-cfg.yml with following content:
```
---
- hosts: home
  tasks:
  - name: Append new lines to config.txt
    blockinfile:
      path: /boot/firmware/config.txt
      block: |
       gpu_mem=16
       dtoverlay=disable-bt
       dtoverlay=disable-wifi
...
```
Run it again with `ansible-playbook append-cfg.yml -K -b`.
Next 2 mods must be enabled with command `ansible home -a "modprobe overlay" -a "modprobe br_netfilter" -K -b`.
Next playbook will create 2 files and add some lines to it. Let's call it _iptable.yml_ and add:
```
---
- hosts: home
  tasks:
  - name: Create a file and write in it 1.
    blockinfile:
      path: /etc/modules-load.d/k8s.conf
      block: |
        overlay
        br_netfilter
      create: yes
  - name: Create a file and write in it 2.
    blockinfile:
      path: /etc/sysctl.d/k8s.conf
      block: |
        net.bridge.bridge-nf-call-ip6tables = 1
        net.bridge.bridge-nf-call-iptables = 1
        net.ipv4.ip_forward = 1
      create: yes
...
```
Run it with `ansible-playbook iptable.yml -K -b`. After that run `ansible home -a "sysctl --system" -K -b`. My PIs started to be laggy so i rebooted here with `ansible home -a "reboot" -K -b`.
Now the last step. Installing some apps on PIs. I'm still unsure if this is needed, but I'm pretty sure it won't harm the cluster. Create a new file _install.yml_ and add copy this:
```
---
- hosts: home
  tasks:
  - name: Install some packages
    apt:
      name:
        - curl
        - gnupg2
        - software-properties-common
        - apt-transport-https
        - ca-certificates
        - linux-modules-extra-raspi
...
```
Now run it with `ansible-playbook install.yml -K -b`.

# Linking OCI with RPi4

Now the fun part is linking the Raspberry Pi cluster to existing k3s cluster on OCI.





# References
Official OCI provider documentation from Terraform - [here](https://registry.terraform.io/providers/oracle/oci/latest/docs);  
Official OCI Oracle documentation with Tutorials - [here](https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm) and Guides - [here](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraform.htm);  
Great GitHub repo of garutilorenzo - [here](https://github.com/garutilorenzo/k3s-oci-cluster). There are a few others who can help you with k8s on OCI too [1](https://arnoldgalovics.com/free-kubernetes-oracle-cloud/) with [repo](https://github.com/galovics/free-kubernetes-oracle-cloud-terraform), [2](https://github.com/r0b2g1t/k3s-cluster-on-oracle-cloud-infrastructure), [3](https://github.com/solamarpreet/kubernetes-on-oci);  
One of my old k3s install on Raspbbery PI article on LinkedIn - [here](https://www.linkedin.com/pulse/creating-arm-kubernetes-cluster-raspberry-pi-oracle-liviu-alexandru) - inspired from [braindose.blog](https://braindose.blog/2021/12/31/install-kubernetes-raspberry-pi/);   
Official Ansible documentation - [here](https://docs.ansible.com/);  
ChatGPT helped me a lot of time, use it [here](https://chat.openai.com/chat).
