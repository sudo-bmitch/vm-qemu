#!/bin/bash

set -euo pipefail

inst_dir="$(dirname $0)"

# source local.env if defined
if [ -f "$inst_dir/local.env" ]; then
  set -a; . "$inst_dir/local.env"; set +a
fi

: "${vmdir:=$HOME/vm}"
: "${net_default:=default}"
: "${base_ip:=10.10.10}"
: "${dns_list:=8.8.8.8, 8.8.4.4}"
: "${base_default:=ubuntu-bionic}"
: "${user_list:=\"default\"}"
: "${user_password:=password123}"

base_pre="base-"
base_env="base.env"
base_image="base.qcow2"
base_meta_tmpl="meta-data.tmpl"
base_user_tmpl="user-data.tmpl"
base_net_tmpl="network-config.tmpl"
stamp=$(date +%Y%m%d-%H%M%S)

opt_b="$base_default"
opt_c=1
opt_h=0
opt_i=""
opt_m="1024"
opt_n=""
opt_N="$net_default"
opt_s="10G"
opt_S=0
virt_inst_opts=""

usage() {
  echo "usage: $(basename $0) [opts]"
  echo "  -b ${opt_b}: base image/seed data name (default ${opt_b})"
  echo "  -c ${opt_c}: number of virtual CPUs to attach (default ${opt_c})"
  echo "  -h: this help message"
  echo "  -i 10: IP address (last octet) (required)"
  echo "  -m ${opt_m}: memory (default ${opt_m})"
  echo "  -n name: Name of VM, used for hostname and VM name (required)"
  echo "  -N ${opt_N}: network (default ${opt_N})"
  echo "  -s ${opt_s}: disk space (default ${opt_s})"
  echo "  -S: disable shared directory"

  [ "$opt_h" = "1" ] && exit 0 || exit 1
}

proc_template() {
  file_in=$1
  file_out=$2
  name="$opt_n" base_ip="$base_ip" end_ip="$opt_i" stamp="$stamp" \
    envsubst '$name $base_ip $end_ip $dns_list $ssh_key_list $stamp $user_list $user_password' <$file_in >$file_out
}

while getopts 'b:c:hi:m:n:N:s:S' option; do
  case $option in
    b) opt_b="$OPTARG";;
    c) opt_c="$OPTARG";;
    h) opt_h=1;;
    i) opt_i="$OPTARG";;
    m) opt_m="$OPTARG";;
    n) opt_n="$OPTARG";;
    N) opt_N="$OPTARG";;
    s) opt_s="$OPTARG";;
    S) opt_S=1;;
  esac
done
shift $(expr $OPTIND - 1)

if     [ $# -gt 0 ] \
    || [ "$opt_h" = "1" ] \
    || [ -z "$opt_n" ] \
    || [ -z "$opt_i" ] ; then
  usage
fi

if [ ! -d "$vmdir" ] || [ ! -w "$vmdir" ]; then
  echo "Error: $vmdir does not exist or no write access" >&2
  exit 1
fi

if     [ ! -d "${vmdir}/${base_pre}${opt_b}" ] \
    || [ ! -f "${vmdir}/${base_pre}${opt_b}/${base_image}" ] \
    || [ ! -f "${vmdir}/${base_pre}${opt_b}/${base_meta_tmpl}" ] \
    || [ ! -f "${vmdir}/${base_pre}${opt_b}/${base_user_tmpl}" ]; then
  echo "Error: base directory miissing required files:" >&2
  echo "${vmdir}/${base_pre}${opt_b}/${base_image}" >&2
  echo "${vmdir}/${base_pre}${opt_b}/${base_meta_tmpl}" >&2
  echo "${vmdir}/${base_pre}${opt_b}/${base_user_tmpl}" >&2
  exit 1
fi

if [ -x "${vmdir}/${base_pre}${opt_b}/${base_env}" ]; then
  set -a; . "${vmdir}/${base_pre}${opt_b}/${base_env}"; set +a
fi

if [ -e "${vmdir}/${opt_n}" ]; then
  echo "Warning: ${vmdir}/${opt_n} already exists" >&2
else
  mkdir "${vmdir}/${opt_n}"
fi

# setup a disk
if [ -f "${vmdir}/${opt_n}/image.qcow2" ]; then
  echo "Warning: ${vmdir}/${opt_n}/image.qcow2 already exists" >&2
else
  # create the OS image based off the base image
  qemu-img create -f qcow2 -o "backing_file=../${base_pre}${opt_b}/${base_image}" "${vmdir}/${opt_n}/image.qcow2" "${opt_s}"
fi

# setup seed file
localds_opts=""
proc_template "${vmdir}/${base_pre}${opt_b}/${base_meta_tmpl}" "${vmdir}/${opt_n}/meta-data"
proc_template "${vmdir}/${base_pre}${opt_b}/${base_user_tmpl}" "${vmdir}/${opt_n}/user-data"
if [ -f "${vmdir}/${base_pre}${opt_b}/${base_net_tmpl}" ]; then
  proc_template "${vmdir}/${base_pre}${opt_b}/${base_net_tmpl}" "${vmdir}/${opt_n}/network-config"
  localds_opts="--network-config ${vmdir}/${opt_n}/network-config"
fi
if [ -f "${vmdir}/${opt_n}/seed.img" ]; then
  echo "Warning: ${vmdir}/${opt_n}/seed.img already exists, recreating" >&2
  rm -f "${vmdir}/${opt_n}/seed.img"
fi
cloud-localds -v "${vmdir}/${opt_n}/seed.img" ${localds_opts} "${vmdir}/${opt_n}/user-data" "${vmdir}/${opt_n}/meta-data"

virtinst_opts=""
if [ "$opt_S" != "1" ]; then
  mkdir -p "${vmdir}/${opt_n}/shared"
  # virtinst_opts="${virtinst_opts} --filesystem type=mount,source=${vmdir}/${opt_n}/shared,target=/shared"
  virtinst_opts="${virtinst_opts} --filesystem type=mount,mode=squash,source=${vmdir}/${opt_n}/shared,target=shared"
  # to use inside the VM, mount with:
  # mount -t 9p -o trans=virtio shared /shared
fi

# create and start VM
#  --controller scsi,model=virtio-scsi \
#  --disk path="${vmdir}/${opt_n}/seed.img",device=cdrom,bus=virtio \
# attempting to fix
# an issue on CentOS throwing kernel errors (NMI received for unknown reason)
#  --features eoi=on \
#  --features acpi=off \
#  --features apic=off \
#  --cpu host \
#  --cpu host-model \
#  --cpu host-model-only \
#  --clock kvmclock_present=no \
#  --virt-type qemu \
set -x
virt-install ${virt_inst_opts} \
  --os-variant ${os_variant:-auto} \
  --name "${opt_n}" \
  --virt-type kvm \
  --graphics none \
  --import \
  --controller scsi,model=auto \
  --disk path="${vmdir}/${opt_n}/image.qcow2",format=qcow2,bus=${virt_inst_bus:-virtio} \
  --disk path="${vmdir}/${opt_n}/seed.img",device=cdrom,bus=${virt_inst_bus:-virtio} \
  --cpu host-model \
  --machine q35 \
  --vcpus "${opt_c}" \
  --memory "${opt_m}" \
  --network network="${opt_N}" \
  ${virtinst_opts} \
  --noautoconsole

echo "Machine created, use \"virsh console ${opt_n}\" to connect"

