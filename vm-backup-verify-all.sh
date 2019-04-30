#!/bin/bash

BACKUP_HOST="$1"
BACKUP_FOLDER="$2"
NBDDEV="${3:-/dev/nbd0}"
VERBOSE="${4:-1}"

export LIBVIRT_DEFAULT_URI="qemu:///system"

if [ -z "$BACKUP_HOST" -o -z "$BACKUP_FOLDER" ]; then
    >&2 echo "Usage: $(basename $0) <backup-host> <backup-folder> [nbd-device=/dev/nbd0] [verbose=1]"
    exit 1
fi

virsh list --all --name | while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    $(dirname "$0")/vm-backup-verify.sh "$domain" "$BACKUP_HOST" "$BACKUP_FOLDER" "$NBDDEV" "$VERBOSE"
    echo
done
