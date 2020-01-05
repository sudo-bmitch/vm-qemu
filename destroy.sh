#!/bin/bash

set -euo pipefail

vmdir="$HOME/vm"
opt_h=0

usage() {
  echo "usage: $(basename $0) [opts]"
  echo "  -n name: Name of VM, used for hostname and VM name (required)"

  [ "$opt_h" = "1" ] && exit 0 || exit 1
}

while getopts 'b:c:hi:m:n:N:s:' option; do
  case $option in
    h) opt_h=1;;
    n) opt_n="$OPTARG";;
  esac
done
shift $(expr $OPTIND - 1) 

if     [ $# -gt 0 ] \
    || [ "$opt_h" = "1" ] \
    || [ -z "$opt_n" ]; then
  usage
fi

virsh destroy "${opt_n}" || true
virsh undefine --nvram "${opt_n}" || true
rm -rf "${vmdir}/${opt_n}"



