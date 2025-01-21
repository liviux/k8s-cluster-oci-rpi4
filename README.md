# Kubernetes Cluster with OCI Free-Tier and Raspberry Pi 4

This is a comprehensive tutorial for deploying a Kubernetes cluster (using k3s) with four Oracle Cloud Infrastructure (OCI) free-tier ARM instances and four Raspberry Pi 4s (or however many you have). Additionally, it covers the installation of essential applications like OpenTofu (replacement of Terraform) and Ansible, along with a suite of tools for managing the cluster, including Lens, MetalLB, Helm, Arkade, Longhorn, Portainer, Argo CD, Prometheus, and Grafana.

I've created a series of articles on [dev.to](https://dev.to/liviux/k8s-cluster-with-oci-free-tier-and-raspberry-pi4-part-1-28k0) based on this repository, but this document will always contain the most up-to-date version.

# Table of Contents

- [Kubernetes Cluster with OCI Free-Tier and Raspberry Pi 4](#kubernetes-cluster-with-oci-free-tier-and-raspberry-pi-4)
- [Table of Contents](#table-of-contents)
    - [OCI](#1-oci)
      - [Requirements](#requirements)
      - [Preparing](#preparing)
      - [Provisioning](#provisioning)
    - [Raspberry Pi 4](#2-raspberry-pi-4)
      - [Requirements](#requirements-1)
      - [Preparing](#preparing-1)
      - [Ansible](#ansible)
    - [Linking OCI with Raspberry Pi 4](#3-linking-oci-with-raspberry-pi-4)
      - [Preparing](#preparing-2)
      - [Netmaker](#netmaker)
      - [Cluster](#cluster)
    - [Other Apps](#4-other-apps)
      - [Lens](#lens)
      - [MetalLB](#metallb)
      - [Helm & Arkade](#helm--arkade)
      - [Bash completion](#bash-completion)
      - [Traefik dashboard](#traefik-dashboard)
      - [Longhorn](#longhorn)
      - [Portainer](#portainer)
      - [Argo CD](#argo-cd)
      - [Prometheus & Grafana](#prometheus--grafana)
- [References](#references)

# 1. OCI

This section covers the Oracle Cloud Infrastructure (OCI) portion of the cluster setup.

## Requirements

-   An OCI account, which you can obtain from [oracle.com/cloud](https://www.oracle.com/cloud/). If you have an existing account, ensure you don't have any resources provisioned (even for other users or compartments), as this tutorial will utilize all the free-tier resources. Be cautious when selecting a region, as popular regions might not have sufficient resources. Choose a region with enough available ARM instances (unfortunately I have no idea how to do that). If OpenTofu gets stuck during the final steps, check **OCI > Compute > Instance Pools** > select your instance pool > **Work requests**. If you see a "Failure" status, examine the log file. An "Out of host capacity" error means you'll need to wait, potentially for days, until resources are freed. You can use a script from [here](https://github.com/hitrov/oci-arm-host-capacity) to attempt instance creation until resources become available. Once successful, quickly delete the created resources in your OCI console and then run the Terraform scripts. Another way to do it is by switching to Pay-as-you-Go model, but if you are not careful you can incur costs. This tutorial should use only Always-Free resources.
-   I used Windows 11 with WSL2 running Ubuntu 20.04, but any Linux machine should work.
-   OpenTofu installed (tested with v1.10.4 and OCI provider v6.21.0). Instructions can be found [here](https://opentofu.org/docs/intro/install/).

## Preparing

For security, it's recommended to use a separate compartment and user for your OCI configuration instead of the root ones. Create a new notes file to store important values that you'll need later. For each value (user, group, compartment), you'll typically add three pieces of information: the name you created, its OCID, and the associated user/group.

1. Go to **Identity & Security > Compartments** and click **Create Compartment**. Open the newly created compartment and copy its **OCID** to your notes file.
2. Go to **Identity & Security > Users** and click **Create User**. Open the user details and copy the **OCID** to your notes file.
3. Go to **Identity & Security > Groups** and click **Create Group**. Copy the **OCID** to your notes file. Click **Add User to Group** and add the newly created user.
4. Go to **Identity & Security > Policies** and click **Create Policy**. Select **Show manual editor** and add the following:

```
allow group <<group_you_created>> to read all-resources in compartment <<compartment_you_created>>
allow group <<group_you_created>> to manage virtual-network-family in compartment <compartment_you_created>
allow group <<group_you_created>> to manage instance-family in compartment <compartment_you_created>
allow group <<group_you_created>> to manage compute-management-family in compartment <compartment_you_created>
allow group <<group_you_created>> to manage volume-family in compartment <compartment_you_created>
allow group <<group_you_created>> to manage load-balancers in compartment <compartment_you_created>
allow group <<group_you_created>> to manage network-load-balancers in compartment <compartment_you_created>
allow group <<group_you_created>> to manage dynamic-groups in compartment <compartment_you_created>
allow group <<group_you_created>> to manage policies in compartment <compartment_you_created>
allow group <<group_you_created>> to manage dynamic-groups in tenancy
```

Next, you'll need to access OCI from your machine. Create a new folder in your home directory:

`mkdir ~/.oci`

Generate a private key:

`openssl genrsa -out ~/.oci/key.pem 2048`

Change the key's permissions:

`chmod 600 ~/.oci/key.pem`

Generate the corresponding public key:

`openssl rsa -pubout -in ~/.oci/key.pem -out ~/.oci/key_public.pem`

Copy the contents of the public key:

`cat ~/.oci/key_public.pem`

Add this public key to your new OCI user. Go to **OCI > Identity & Security > Users**, select the new user, open **API Keys**, click **Add API Key**, select **Paste Public Key**, and paste the copied key. After adding the key, copy the fingerprint to your notes file. Also, save the path to the private key.

*Note: Use `~` instead of `$HOME` for the path, as it might be necessary for proper functionality.*

Add the following to your notes file:

-   **Tenancy OCID**: Click on your avatar (top-right) and select **Tenancy**.
-   **Region**: The region name is in the top-right corner. Find it [here](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm) and copy its identifier (e.g., eu-paris-1).
-   **Private key path**: In this case, `~/.oci/key.pem`

Now, create a new folder to test if OpenTofu is correctly linked with OCI. Inside that folder, create a file named `main.tf` and add the following content:

```
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "4.120.0"
    }
  }
}

# Configure the OCI provider with an API Key

provider "oci" {
  tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaYOURTENANCY3uzx4a"
  user_ocid        = "ocid1.user.oc1..aaaaaaYOURUSER4s5ga"
  private_key_path = "~/.oci/key.pem"
  fingerprint      = "2a:d8:YOURFINGERPRINT:a1:cd:06"
  region           = "eu-YOURREGION"
}

# Get a list of Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = "ocid1.tenancy.oc1..aaaaaaYOURTENANCYuzx4a"
}

# Output the result
output "all-availability-domains-in-your-compartment" {
  value = data.oci_identity_availability_domains.ads.availability_domains
}
```

Run `tofu init` to download the OCI provider, `tofu plan` to preview the changes, and `tofu apply` to execute. This configuration should return the names of the availability domains in your region. If you see something like `"name" = "pmkj:EU-YOURREGION-1-AD-1"` without errors, your setup is correct so far. You can delete this test file now.

## Provisioning

You'll need to add a few more values to your notes file:

-   In the OCI console, click **Developer Tools > Cloud Shell** (top-right corner) and run `oci iam availability-domain list`. Save the name of the availability domain (not the ID) - if many pick one. This is your `availability_domain` variable. Should be the same results as from running the test above.
-   In the same Cloud Shell, run `oci compute image list --compartment-id <YOUR-COMPARTMENT> --operating-system "Canonical Ubuntu" --operating-system-version "24.04 Minimal aarch64" --shape "VM.Standard.A1.Flex"` to find the OS Image ID. The first result is likely the latest build (e.g., `Canonical-Ubuntu-24.04-Minimal-aarch64-2024.10.08-0`). Save the ID. This is your `os_image_id` variable.
-   Search for "my IP" on Google to find your public IP address. Save it in CIDR format (e.g., `111.222.111.99/32`). This is your `my_public_ip_cidr` variable. If you don't have a static IPv4 address from your ISP, consider using a cheap VPS with a static IP (highly recommended) or setting up DDNS. However, DDNS might not be usable in Security Lists. Alternatively, you'll need to manually update the Ingress rule in your VCN's Security List with your new IP each time it changes, or set the Ingress rule to `0.0.0.0/0` to allow all traffic (absolutely not recommended for security reasons).
-   Your `public_key_path` is the path to your public SSH key. If you don't have one, generate it with `ssh-keygen`. It should be located at `~/.ssh/id_rsa.pub` (or a similar name with `.pub`). You might want to copy the private key to your VPS using `scp` to connect to OCI from both your local machine and the VPS.
-   Finally, provide an email address for installing a certificate manager. This will be your `certmanager_email_address` variable.

After cloning this repository, navigate to `oci/terraform.tfvars` and edit the values with those from your notes file. This build uses the great Terraform configuration from [garutilorenzo's repository](https://github.com/garutilorenzo/k3s-oci-cluster) (check for updates since 2024-Jan if you encounter errors). You can customize your configuration by editing `main.tf` as explained [here](https://github.com/garutilorenzo/k3s-oci-cluster#pre-flight-checklist). Other options that I edited (to use latest versions and other config) are `k3s_server_pool_size = 1`,  `k3s_worker_pool_size = 2`, `longhorn_release = v1.7.2`,   `nginx_ingress_release = v1.12.0`, `certmanager_release = v1.16.3`, `argocd_release = v2.13.3`, `argocd_image_updater_release = v0.15.2`.

*Note: If you experience clock synchronization issues with WSL2, verify the time with the `date` command. If it's out of sync, run `sudo hwclock -s` or `sudo ntpdate time.windows.com`.*

Run `tofu plan` and then `tofu apply`. If successful, your resources will be created in OCI.

When the script finishes, save the outputs (or find them in the OCI console):

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
  },
])
```

You can now connect to any worker or server using `ssh -i ~/.ssh/your_private_key ubuntu@<server_or_worker_ip>`. Connect to the server and run `sudo kubectl get nodes` to check the nodes.

If your cluster encounters issues, you can delete the resources in your compartment (go to **Governance & Administration > Tenancy Management > Tenancy Explorer**) one by one (or try `tofu destroy`, but it might not always work). Deleting the VCN can be particularly challenging. Afterward, rerun `tofu apply` (if resources are available). We don't focus too much on OpenTofu/Terraform best practices (like storing state, environment variables, or many more other configurations) as these resources will be provisioned and forgotten, there are slim chances OCI will give more compute resources in the future (hoping they will not remove some of them).

# 2. Raspberry Pi 4

This section focuses on the Raspberry Pi 4 (RPi4) component of the cluster.

## Requirements

-   At least two Raspberry Pi 4s. I have four: three with 4GB of RAM and one with 8GB. Each one needs an SD card, a power adapter, network cables (optionally a network switch), and cases.
-   The same setup as in Part 1: Windows 11 with WSL2 running Ubuntu 20.04 (or any Linux machine).

![my setup](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/0edbmj9h7vt1ls8805nd.jpg) My Pis

## Preparing

Installing an OS on a Raspberry Pi is straightforward. Insert the SD card into your PC and use the Raspberry Pi Imager from the [official website](https://www.raspberrypi.com/software/). I chose the same OS as the OCI cluster: Ubuntu Server 24.04 64-bit. In the Imager's advanced settings (bottom-right), select **Set Hostname** and choose a name for each Pi (e.g., rpi4-1, rpi4-2, rpi4-3, rpi4-4). Select **Enable SSH** and **Set username and password** to enable immediate SSH access without a monitor and keyboard. Click **Write** and repeat for each Raspberry Pi.

Find the IP addresses of your Raspberry Pis from your home router's interface. You can also configure **Address Reservation** there to ensure they retain the same IPs. If you want to access them from outside your network and don't have a static IPv4 address, consider setting up port forwarding and using a DDNS service from your ISP. These settings are typically configured in your router's interface, so search online for instructions if needed.

Add each Raspberry Pi to your local machine's `C:\Windows\System32\drivers\etc\hosts` file for easier management:

```
192.168.0.201 rpi4-1
192.168.0.202 rpi4-2
192.168.0.203 rpi4-3
192.168.0.204 rpi4-4
```

Test the connection by running `ping rpi4-1` or `ssh user@rpi4-1`.

## Ansible

I chose Ansible for configuration management because it's agentless and relatively easy to use (although it can be complex at times). You can control all your RPi4s from your local machine. Install Ansible with `sudo apt install ansible`.

Assuming you generated SSH keys in Part 1, run the following commands from your PC:

```
ssh-copy-id -i ~/.ssh/id_rsa.pub user@rpi4-1
ssh-copy-id -i ~/.ssh/id_rsa.pub user@rpi4-2
ssh-copy-id -i ~/.ssh/id_rsa.pub user@rpi4-3
ssh-copy-id -i ~/.ssh/id_rsa.pub user@rpi4-4
```

This allows Ansible to connect to each Pi without requiring a password each time.

You might need to uncomment the line `private_key_file = ~/.ssh/id_rsa` in `/etc/ansible/ansible.cfg` using `sudo vi /etc/ansible/ansible.cfg`.

In `/etc/ansible/hosts`, add the following:

```
[big]
rpi4-1  ansible_connection=ssh

[small]
rpi4-2  ansible_connection=ssh
rpi4-3  ansible_connection=ssh
rpi4-4  ansible_connection=ssh

[home:children]
big
small
```

This creates groups for your Raspberry Pis: "big" for the 8GB Pi, "small" for the 4GB Pis, and "home" for all of them. If your PC user and Raspberry Pi users are different, add this to the same file:

```
[all:vars]
remote_user = user
```

Test the Ansible connection with `ansible home -m ping`. A green response indicates success.

To keep your systems updated, create a new file named `update.yml` and paste the following Ansible playbook:

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

This playbook updates Ubuntu and reboots the Raspberry Pis if necessary. Run it with `ansible-playbook update.yml -K -b`, which will prompt for the sudo password. You can monitor the activity on each Pi using `htop` in a separate SSH session.

Check for firmware updates with `ansible home -a "rpi-eeprom-update -a" -b -K`.

Next, enable cgroups on each Pi. Create a new playbook named `append-cmd.yml` with the following content:

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

This appends `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt`. Run it with `ansible-playbook append-cmd.yml -K -b`.

To free up some memory for Kubernetes, we'll disable the graphical interface, Wi-Fi, and Bluetooth. Create a new playbook named `append-cfg.yml`:

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

Run it with `ansible-playbook append-cfg.yml -K -b`.

Enable two kernel modules with `ansible home -a "modprobe overlay" -a "modprobe br_netfilter" -K -b`.

Create a new playbook named `iptable.yml` to configure iptables:

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

Run it with `ansible-playbook iptable.yml -K -b`. Then, apply the sysctl settings with `ansible home -a "sysctl --system" -K -b`. If your Raspberry Pis become sluggish, reboot them with `ansible home -a "reboot" -K -b`.

Finally, install some useful packages. Create a new file named `install.yml`:

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

Run it with `ansible-playbook install.yml -K -b`.

# 3. Linking OCI with Raspberry Pi 4

Now, let's connect the Raspberry Pi cluster to the existing k3s cluster on OCI.

## Preparing

Add the OCI machines to your `C:\Windows\System32\drivers\etc\hosts` file (WSL reads and updates its `/etc/hosts` file accordingly):

```
...
192.168.0.201   rpi4-1
192.168.0.202   rpi4-2
192.168.0.203   rpi4-3
192.168.0.204   rpi4-4
140.111.111.213 oci1
140.112.112.35  oci2
152.113.113.23  oci3
140.114.114.22  oci4
```

Add them to your Ansible hosts file (`/etc/ansible/hosts`) as well:

```
[big]
rpi4-1  ansible_connection=ssh
[small]
rpi4-2  ansible_connection=ssh
rpi4-3  ansible_connection=ssh
rpi4-4  ansible_connection=ssh
[home:children]
big
small
[ocis]
oci1    ansible_connection=ssh ansible_user=ubuntu
[ociw]
oci2   ansible_connection=ssh ansible_user=ubuntu
oci3   ansible_connection=ssh ansible_user=ubuntu
oci4   ansible_connection=ssh ansible_user=ubuntu
[oci:children]
ocis
ociw
[workers:children]
big
small
ociw
```

This naming convention works, though it might not be the most elegant. You can interact with all hosts using `ansible -m command all`. Test it with `ansible -a "uname -a" all`. You should receive eight responses, one from each Linux machine. You can also rerun the `update.yml` playbook to update the OCI instances.

K3s supports various architectures ([see here](https://docs.k3s.io/architecture)). We'll use the **High Availability with Embedded DB** architecture, which uses etcd instead of the default SQLite. With etcd, it's crucial to have an odd number of server nodes for quorum (as explained in the official documentation: "_An etcd cluster needs a majority of nodes, a quorum, to agree on updates to the cluster state. For a cluster with n members, quorum is (n/2)+1._").

Initially, the plan was to have three server nodes (two from OCI and one from RPi4). However, due to potential issues with etcd when server nodes are on different networks (see [issue 1](https://github.com/k3s-io/k3s/issues/2850) and [issue 2](https://github.com/k3s-io/k3s/issues/6297) on GitHub), we'll use **one server node** (the master node in k3s terminology) from OCI and **seven agent nodes** (worker nodes) – three from OCI and four from RPi4.

You may want to open ports to allow communication between the OCI and Raspberry Pi clusters. Go to **VCN > Security List** and click **Add Ingress Rule**. While you could open only the necessary ports for k3s networking ([listed here](https://docs.k3s.io/installation/requirements#networking)), I opted to open all ports on the OCI instances to my public IP, as there's minimal risk in this setup. Select **All Protocols** for **IP Protocol**. You can now test connectivity by SSHing into any RPi4 and trying to ping or SSH into an OCI machine or access other ports (this step might be optional after setting up Netmaker).

## Netmaker

To link all the machines, we'll create a VPN using **WireGuard**. While WireGuard can be complex to configure manually, **Netmaker** simplifies the process significantly.

On your VPS or local machine (if it has a static IP), run:

`sudo wget -qO /root/nm-quick-interactive.sh https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/nm-quick-interactive.sh && sudo chmod +x /root/nm-quick-interactive.sh && sudo /root/nm-quick-interactive.sh`

Follow the prompts, selecting the Community Edition (up to 50 nodes) and choosing automatic options for the rest.

After installation, you'll have a dashboard at an auto-generated domain. Open the link you received, create a user and password.

A network should have been created for you. Go to the **Network** tab and open the network. You can adjust settings if needed. I changed the CIDR to `10.20.30.0/24` and enabled **UDP Hole Punching** for better NAT traversal. Go to the **Access Key** tab, select your network, and you'll find the keys to connect your machines.

The Netmaker client, `netclient`, requires `wireguard` and `systemd`. Create a new Ansible playbook named `wireguard_install.yml`:

```
---
- hosts: all
  tasks:
  - name: Install wireguard
    apt:
      name:
        - wireguard
...
```

Run it with `ansible-playbook wireguard_install.yml -K -b`. Verify the installation with `ansible -a "wg --version" all` and `ansible -a "systemd --version" all`.

Create another playbook named `netclient_install.yml`:

```
---
- hosts: all
  tasks:
  - name: Add the Netmaker GPG key
    shell: curl -sL 'https://apt.netmaker.org/gpg.key' | sudo tee /etc/apt/trusted.gpg.d/netclient.asc

  - name: Add the Netmaker repository
    shell: curl -sL 'https://apt.netmaker.org/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/netclient.list

  - name: Update the package list
    shell: apt update

  - name: Install netclient
    shell: apt install netclient
...
```

Run it with `ansible-playbook netclient_install.yml -K -b`. This installs `netclient` on all hosts. Verify with `ansible -a "netclient --version" all`.

Finally, run `ansible -a "netclient join -t YOURTOKEN" -b -K`, replacing `YOURTOKEN` with the **Join Command** from your Netmaker dashboard under **Access Key**. This connects all hosts to the same WireGuard network. Here's my network with 11 machines (4 RPi4s, 4 OCI instances, my VPS, my WSL machine, and my Windows machine – the last three are optional):

![netmaker network](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/587lg95xqlle3e2i573n.png)

## Cluster

SSH into the OCI server and run:
1. `sudo systemctl stop k3s`
2. `sudo rm -rf /var/lib/rancher/k3s/server/db/etcd`
3. `curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-iface=nm-netmaker --disable=servicelb" INSTALL_K3S_CHANNEL=latest sh -`

*Note: It might be possible to just reinstall k3s without the first two commands. Alternatively, you could append the following lines to the end of `/etc/systemd/system/k3s.service` (after which you'd run `sudo systemctl daemon-reload` and `sudo systemctl restart k3s`):*

```
ExecStart=/usr/local/bin/k3s \
    server \
        '--flannel-iface=nm-netmaker' \
        '--disable=servicelb' \
```

For the agent nodes, create an Ansible playbook named `workers_link.yml`:

```
---
- hosts: workers
  tasks:
  - name: Install k3s on workers and link to server node
    shell: curl -sfL https://get.k3s.io | K3S_URL=https://10.20.30.1:6443 K3S_TOKEN=MYTOKEN INSTALL_K3S_EXEC="--flannel-iface=nm-netmaker" INSTALL_K3S_CHANNEL=latest sh -s -
...
```

Replace `MYTOKEN` with the content of `/var/lib/rancher/k3s/server/node-token` on the server and adjust the server's IP address if necessary. Run it with `ansible-playbook ~/ansible/link/workers_link.yml -K -b`.

You're done! Go back to the server node and run `sudo kubectl get nodes -owide`. You should see eight nodes: one master and seven workers.
I've added some labels to nodes (e.g., add them with `sudo kubectl label node <server-node-name> region=eu-frankfurt-1`). This are my options: 
|Node Type   |Suggested Labels   |
|---|---|
|OCI ARM Nodes   |region=eu-frankfurt-1, cloud=oci, arch=arm64, storage=block-volume, performance=high, ram=6gb, hardware-type=oci-arm, node-role=server (for the k3s server),   |
|Raspberry Pi (8GB)   |region=ro-bucharest, edge=true, arch=arm64, storage=hdd, performance=medium, ram=8gb, hardware-type=raspberry-pi-4    |
|Raspberry Pi (4GB)   |region=ro-bucharest, edge=true, arch=arm64, storage=sdcard, performance=low, ram=4gb, hardware-type=raspberry-pi-4    |

# 4. Other Apps

I'll briefly cover the installation of these applications and how to access them. You'll need to configure them further and run demo applications to learn how to use them effectively.

## Lens

[Lens](https://k8slens.dev/) is a beautiful Kubernetes dashboard. Install the desktop application on your PC, go to **File > Add Cluster**. On the server, run `kubectl config view --minify --raw` and paste the output into Lens. Replace `127.0.0.1:6443` in the output with your server's IP address (e.g., `10.20.30.1:6443`).

## MetalLB

MetalLB acts as a load balancer, providing external IPs to services of type `LoadBalancer`. Install it with:

`kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml`

Create a file named `config-metallb.yaml` with the following content:

```
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 192.168.0.150 - 192.168.0.250

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
```

Adjust the IP range to match your home network. Apply it with `kubectl apply -f config-metallb.yaml`. Now, you can use the external IPs provided by MetalLB instead of node IPs and ports when accessing services.

## Helm & Arkade

If Git isn't installed on the server, run `sudo apt install git`. Also, set the `KUBECONFIG` environment variable by adding this line to `~/.bashrc`:

```
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```
Reload your bash with `source ~/.bashrc`
Helm is the package manager for Kubernetes. Install it with:

```
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

Arkade is an open-source marketplace for Kubernetes. Install it with:

`curl -sLS https://get.arkade.dev | sudo sh`

## Bash completion

For faster and easier command execution, enable auto-completion for `kubectl`. Run:

```bash
apt install bash-completion
echo 'source <(kubectl completion bash)' >>~/.bashrc
bash
```

Now, after typing `kubectl`, you can press Tab to auto-complete commands and resource names. Try it with `kubectl get pod` and then press Tab.

## Traefik dashboard

Create a YAML file named `traefik-crd.yaml` and apply it. The content should be:

```
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--api"
      - "--api.dashboard=true"
      - "--api.insecure=true"
      - "--log.level=DEBUG"
    ports:
      traefik:
        expose: true
    providers:
      kubernetesCRD:
        allowCrossNamespace: true
```
Apply with `kubectl apply -f traefik-crd.yaml`. The dashboard should be available at `http://<any_node_ip>:9000/dashboard/#/` (e.g., `http://10.20.30.4:9000/dashboard/#


## Longhorn

Longhorn provides cloud-native distributed block storage for Kubernetes. First, create a new Ansible playbook named `install-longhorn.yml`:

```
---
- hosts: all
  tasks:
  - name: Install some package for Longhorns
    apt:
      name:
        - nfs-common
        - open-iscsi
        - util-linux
...
```

Run it with `ansible-playbook install-longhorn.yml -K -b` to install necessary components on the nodes.

On the server, run:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
```

This process might take around 7 minutes.

Create a file named `longhorn-service.yaml` with the following content:

```
apiVersion: v1
kind: Service
metadata:
  name: longhorn-ingress-lb
  namespace: longhorn-system
spec:
  selector:
    app: longhorn-ui
  type: LoadBalancer
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
```

Apply it with `kubectl apply -f longhorn-service.yaml`.

You can now access the Longhorn dashboard in your browser at `http://<any_node_ip>:<port>`. To find the port, run:

`kubectl describe svc longhorn-ingress-lb -n longhorn-system | grep NodePort`

To make Longhorn the default StorageClass, run:

```bash
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
Now you should see only Longhorn with default `kubectl get storageclass`.

## Portainer

Portainer is a container management platform. Install it using Helm:

```bash
helm repo add portainer https://portainer.github.io/k8s/
helm repo update
helm install --create-namespace -n portainer portainer portainer/portainer
```

You can access the Portainer UI at `http://<any_node_ip>:30777` (e.g., `http://10.20.30.1:30777`). It uses 10 GB of storage, which you can verify with `kubectl get pvc -n portainer` (you should also see the new volume in your Longhorn dashboard). Create a user and password in the Portainer UI. After clicking "Get Started," you should see your cluster.

![portainer](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/v4ggrycif2pqk6n4a1o5.png)

## Argo CD

Argo CD is a declarative, GitOps continuous delivery tool for Kubernetes. Install it with:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait a few minutes or monitor the progress with `kubectl get all -n argocd`.

To access the UI, change the service type to `LoadBalancer`:

`kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'`

Find the port with:

`kubectl describe service/argocd-server -n argocd | grep NodePort`

Access the UI at `http://<any_node_ip>:<port>`. The username is `admin`, and you can retrieve the password with:

`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo`

## Prometheus & Grafana

Prometheus is a popular metrics system from the CNCF landscape, and Grafana is often used as its dashboard. We'll install them using the official `kube-prometheus-stack` Helm chart via Argo CD.

In the Argo CD UI, go to **Applications** and click **New App**. Configure the following:

-   **Application Name**: `kube-prometheus-stack`
-   **Project Name**: `default`
-   **Sync Policy**: `Automatic`
-   Check **Auto-Create Namespace**
-   Check **Self Heal**
-   Check **Prune Resources**
-   **Repository URL**: `https://prometheus-community.github.io/helm-charts` (select **Helm**)
-   **Chart**: `kube-prometheus-stack`
-   **Cluster URL**: `https://kubernetes.default.svc`
-   **Namespace**: `kube-prometheus-stack`
-   **Values**
    ```
    alertmanager:
      service:
        type: LoadBalancer
    prometheus:
      service:
        type: LoadBalancer
    prometheusOperator:
      service:
        type: LoadBalancer
    grafana:
      ingress:
        enabled: true
    ```

Click **Create**. We've configured the services as `LoadBalancer` because the default type is `ClusterIP`, which would require port forwarding for external access.

You can access the Prometheus UI at `http://<any_node_ip>:<port>`. Find the port with:

`kubectl describe svc kube-prometheus-stack-prometheus -n kube-prometheus-stack | grep NodePort`

Similarly, access the Prometheus Alert Manager using the port obtained from:

`kubectl describe svc kube-prometheus-stack-alertmanager -n kube-prometheus-stack | grep NodePort`

For the Grafana dashboard, go to `http://<any_node_ip>/kube-prometheus-stack-grafana:80`. The username is `admin`, and you can get the password with:

`kubectl get secret --namespace kube-prometheus-stack kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`

# References

-   k3s Documentation: [https://k3s-io.github.io/docs](https://k3s-io.github.io/docs)
-   OCI provider documentation from Terraform: [https://registry.terraform.io/providers/oracle/oci/latest/docs](https://registry.terraform.io/providers/oracle/oci/latest/docs)
-   OCI Oracle documentation with Tutorials: [https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm](https://docs.oracle.com/en-us/iaas/developer-tutorials/tutorials/tf-provider/01-summary.htm)
-   OCI Oracle Guides: [https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraform.htm](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/terraform.htm)
-   Great GitHub repo by garutilorenzo: [https://github.com/garutilorenzo/k3s-oci-cluster](https://github.com/garutilorenzo/k3s-oci-cluster)
-   Other helpful resources for k8s on OCI:
    -   [https://arnoldgalovics.com/free-kubernetes-oracle-cloud/](https://arnoldgalovics.com/free-kubernetes-oracle-cloud/) with [repo](https://github.com/galovics/free-kubernetes-oracle-cloud-terraform)
    -   [https://github.com/r0b2g1t/k3s-cluster-on-oracle-cloud-infrastructure](https://github.com/r0b2g1t/k3s-cluster-on-oracle-cloud-infrastructure)
    -   [https://github.com/solamarpreet/kubernetes-on-oci](https://github.com/solamarpreet/kubernetes-on-oci)
-   My old k3s install on Raspberry Pi article on LinkedIn: [https://www.linkedin.com/pulse/creating-arm-kubernetes-cluster-raspberry-pi-oracle-liviu-alexandru](https://www.linkedin.com/pulse/creating-arm-kubernetes-cluster-raspberry-pi-oracle-liviu-alexandru) (inspired by [https://braindose.blog/2021/12/31/install-kubernetes-raspberry-pi/](https://braindose.blog/2021/12/31/install-kubernetes-raspberry-pi/))
-   Ansible documentation: [https://docs.ansible.com/](https://docs.ansible.com/)
-   Etcd documentation: [https://etcd.io/docs/v3.5/faq/](https://etcd.io/docs/v3.5/faq/)
-   More on why 3 server nodes are recommended: [https://www.siderolabs.com/blog/why-should-a-kubernetes-control-plane-be-three-nodes/](https://www.siderolabs.com/blog/why-should-a-kubernetes-control-plane-be-three-nodes/)
-   Netmaker: [https://github.com/gravitl/netmaker](https://github.com/gravitl/netmaker)
-   Netmaker documentation: [https://netmaker.readthedocs.io/en/master/install.html](https://netmaker.readthedocs.io/en/master/install.html)
-   A great, comprehensive guide for running Kubernetes on Raspberry Pi: [https://rpi4cluster.com/](https://rpi4cluster.com/)
-   For each application installed, refer to its official documentation.
-   ChatGPT was a great help; use it here: [https://chat.openai.com/chat](https://chat.openai.com/chat)

That concludes the improved and completed README. Let me know if you have any other questions.
