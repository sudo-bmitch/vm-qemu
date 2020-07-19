# VM environment


## Requirements

Built with:

- qemu: virtualization runtime
- kvm: kernel VM method
- libvirt: VM management (networks, restart on reboot)
- cloud-init: setup OS inside new VM's

## Setup

### Hardware

The bios needs to be configured to permit virtualization for KVM support.

### Linux Packages

On Debian, the following are installed:

- cloud-image-utils
- libvirt-clients
- libvirt-daemon
- libvirt-daemon-system
- qemu
- qemu-kvm
- qemu-utils
- virtinst

### Networks

Create xml templates for your networks, e.g. `net-nat.xml`:

```
<network>
  <name>nat</name>
  <bridge name="virbr1"/>
  <forward mode="nat"/>
  <ip address="10.10.10.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.10.10.200" end="10.10.10.254"/>
    </dhcp>
  </ip>
  <!-- <ip family="ipv6" address="2001:db8:ca2:2::1" prefix="64"/> -->
</network>
```

Or for routed networking, a `net-routed.xml`:

```
<network>
  <name>routed</name>
  <bridge name="virbr1"/>
  <forward mode="route"/>
  <ip address="10.10.11.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.10.11.200" end="192.168.238.254"/>
    </dhcp>
  </ip>
  <!-- <ip family="ipv6" address="2001:db8:ca2:2::1" prefix="64"/> -->
</network>
```

Note for routed, routing needs to be configured on the external network router.
Then the networks can be created and enabled with:

```
virsh net-define net-nat.xml
virsh net-start nat
virsh net-autostart nat
virsh net-define net-routed.xml
virsh net-start routed
virsh net-autostart routed
```

### local.env

A `local.env` file is created with:

```
vmdir="/path/to/vms"
net_default="default" # change to nat or routed
base_ip="10.10.10" # first 3 octants of the network
dns_list="8.8.8.8, 8.8.4.4" # include local DNS server
base_default="debian-10" # local base image
user_password="password123" # password added to default user

ssh_key_list="\"ssh-rsa AAAA..... user@host1\""
ssh_key_list="$ssh_key_list, \"ssh-rsa AAAA..... user@host2\""

user_list="\"default\", {\"name\": \"username\", \"gecos\": \"Your Name\", \"shell\": \"/bin/bash\", \"passwd\": \"......\", \"sudo\": \"ALL=(ALL) NOPASSWD:ALL\", \"groups\": \"users\", \"ssh_import_id\": \"None\", \"lock_passwd\": \"false\", \"ssh_authorized_keys\": [ $ssh_key_list ] }"
```

Create a hashed user password for the above passwd field with:

```
mkpasswd --method=SHA-512 --rounds=4096
```

These variables are used in the base image files.

## Build New Base Image

The following example is for a Debian 10 image:

- Create the VM image and start VM:

  ```
  mkdir base-debian-10-build base-debian-10
  qemu-img create -f qcow2 base-debian-10-build/setup.qcow2 5G
  virt-install \
    --virt-type kvm \
    --name base-debian-10-build \
    --ram 1024 \
    --cdrom cdrom/debian-10.0.0-amd64-netinst.iso \
    --disk path=base-debian-10-build/setup.qcow2,format=qcow2,bus=scsi \
    --network network=${net_default} \
    --graphics vnc,password=qemu,listen=0.0.0.0 \
    --os-type linux \
    --os-variant debian9 \
    --cpu host \
    --vcpus 2 
  ```  
  - Note: VNC is required since CDROM does not support text console.
  - Connect with VNC from laptop: `vncviewer localhost`

- Install prompts:
  - Hostname: debian
  - Domain: blank
  - Network: (get vars from local.env)
    - IP: ${base_ip}.2/24
    - GW: ${base_ip}.1
    - DNS: ${dns_list}
  - Root PW: none
  - Username: debian
  - User pass: debian (does not matter, replaced by cloud init later)
  - TZ: Eastern
  - Partition:
    - 100 MB boot, bootable
    - Remainder /
  - Packages: ssh, standard system
  - Before shutdown, open a console:
    - edit /etc/default/grub with `GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"`
    - run `update-grub`
  - After reboot starts, hard shutdown:
    `virsh destroy base-debian-10-build`
- Snapshot and restart without graphics:
  ```
  virsh destroy base-debian-10-build
  virsh undefine base-debian-10-build
  sudo qemu-img snapshot -c base-os base-debian-10-build/setup.qcow2
  virt-install \
    --virt-type kvm \
    --name base-debian-10-build \
    --graphics none \
    --ram 1024 \
    --import \
    --disk path=base-debian-10-build/setup.qcow2,format=qcow2,bus=scsi \
    --network network=${net_default} \
    --os-type linux \
    --os-variant debian9 \
    --cpu host \
    --vcpus 2 
  ```

- Post Reboot Steps:
  - `sudo -s`
  - Fix /etc/network/interfaces for ens2/ens3 naming, `ifup ens2`
    - Is this needed?
    - `touch /etc/udev/rules.d/70-persistent-net.rules`
    - `touch /lib/udev/rules.d/75-persistent-net-generator.rules`
  - `apt-get update`
  - `apt-get upgrade`
  - `apt-get install cloud-init cloud-utils cloud-initramfs-growroot`
  - Verify entry in /etc/cloud/cloud.cfg the following to `default_user`:
    `sudo: ["ALL=(ALL) NOPASSWD:ALL"]`
  - Include other packages you may want (curl, git, jq, tmux, etc)
    - `apt-get install curl git jq tmux unzip`
  - Is this needed? Clean IP's from /etc/network and /etc/resolve.conf
  - Is this needed? Cleanup:
    ```
    cat /dev/null > ~/.bash_history && history -c
    sudo -s
    cat /dev/null > /var/log/wtmp
    cat /dev/null > /var/log/btmp
    cat /dev/null > /var/log/lastlog
    cat /dev/null > /var/run/utmp
    cat /dev/null > /var/log/auth.log
    cat /dev/null > /var/log/kern.log
    cat /dev/null > /var/mail/debian
     cat /dev/null > ~/.bash_history
     history -c
     shutdown -h now
    ```
  - `virsh destroy base-debian-10-build` (should error)
  - `virsh undefine base-debian-10-build`

- Compact/copy, and use as new base image
  - Remove Snapshot: `sudo qemu-img snapshot -d base-os base-debian-10-build/setup.qcow2`
  - Compact: `sudo qemu-img convert -f qcow2 -O qcow2 base-debian-10-build/setup.qcow2 base-debian-10/base.qcow2`

## Templates and Other Base Image Files

The base image should be named base.qcow2. In the same directory, you need:

- base.env: variables used when running virt-install. For base-debian-10, this looks like:
  ```
  # the debian10 variant wasn't availabe as of the creation of this image
  os_variant="debian9"
  # virt_inst_opts=""
  # the inst_bus may vary depending on how the base image was created
  virt_inst_bus='scsi'
  ```

- meta-data.tmpl: used with cloud-init:
  ```
  instance-id: iid-${name}-${stamp}
  hostname: ${name}
  local-hostname: ${hostname}
  ```

- network-config.tmpl: used with cloud-init:
  ```
  ---
  version: 1
  config:
  - type: physical
    # physical interface name varies, use `virsh console` to login and check `ip a`
    name: enp0s1
    # mac_address: INSTANCE_MAC_GOES_HERE
    subnets:
    - type: static
      address: ${base_ip}.${end_ip}
      netmask: 255.255.255.0
      routes:
      - network: 0.0.0.0
        netmask: 0.0.0.0
        gateway: ${base_ip}.1
  - type: nameserver
    address: [ ${dns_list} ]
    search: []
  ```

- user-data.tmpl: used with cloud-init:
  ```
  #cloud-config
  users: [ ${user_list} ]
  
  chpasswd:
    list: |
      debian:${user_password}
    #  root:root
    expire: False
  ssh_pwauth: True
  
  package_update: true
  # install packages that may be missing from upstream base image
  packages:
  # - python3
  
  bootcmd:
  # disable automatic dhcp
  - sed -e '/^#/! {/eth0/ s/^/# /}' -i /etc/network/interfaces
  ```

## Provisioning

- Provision 10 nodes with debian-10 base image from ip 30-39:
  ```
  base=debian-10
  for i in $(seq 0 9); do ./provision.sh -b ${base} -n vm-${i} -c 2 -i 3${i} -m 2048 -s 20G; done
  ```

- Destroy VM's
  ```
  for i in $(seq 0 9); do ./destroy.sh -n vm-${i}; done
  ```

- Describe each base image:
  ```
  for file in */image.qcow2; do echo "$(dirname $file)"; qemu-img info --output json "${file}"  | jq '."backing-filename"' | cut -f 2 -d/; done
  ```

## Configure base image pool

This is used for Terraform commands, it is not needed for the `provision.sh` script.

```
# create a base-img dir
mkdir base-img
ln -s base-debian-10/base.qcow2 base-img/debian-10.qcow2
  # repeat for other images
# create the pool
virsh pool-define-as base-img dir --target "$(pwd)/base-img"
virsh pool-build base-img
# start the pool and configure autostart
virsh pool-start base-img
virsh pool-autostart base-img
# show the resulting pool and volumes
virsh pool-info base-img
virsh vol-list base-img
```


