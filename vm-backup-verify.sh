#!/bin/bash

set -e

DOMAIN="$1"
BACKUP_HOST="$2"
BACKUP_FOLDER="$3"
NBDDEV="${4:-/dev/nbd0}"

case $5 in
    "")
        VERBOSE=true;;
    1)
        VERBOSE=true;;
    true)
        VERBOSE=true;;
    0)
        VERBOSE=false;;
    false)
        VERBOSE=false;;
    *)
        >&2 echo "verbose must be '1', 'true', '0', or 'false'."
        exit 2;;
esac

if [ -z "$DOMAIN" -o -z "$BACKUP_HOST" -o -z "$BACKUP_FOLDER" ]; then
    >&2 echo "Usage: $(basename $0) <domain> <backup-host> <backup-folder> [nbd-device=/dev/nbd0] [verbose=1]"
    exit 1
fi

export LIBVIRT_DEFAULT_URI="qemu:///system"

if ! virsh dominfo "$DOMAIN" > /dev/null 2>&1; then
    >&2 echo "Domain '$DOMAIN' does not exist."
    exit 3
fi

$VERBOSE && echo "Verifying backup of domain $DOMAIN."

BACKUP_FOLDER="$BACKUP_FOLDER/$DOMAIN"

function get_backing() {
    qemu-img info -U "$1" | sed -n 's/^backing file: //p'
}
function get_backing_chain() {
    qemu-img info -U --backing-chain "$1" | sed -n 's/^image: //p'
}
function get_chain_base() {
    get_backing_chain "$1" | tail -1
}

virsh domblklist "$DOMAIN" --details | sed -n 's/^ *file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | while IFS=: read -r target file; do
    base="$(get_chain_base "$file")"
    if [[ "$base" == *"nobackup"* ]]; then
        continue
    fi
    backing="$(get_backing "$file")"

    if [[ "$file" == "$backing" ]]; then
        >&2 echo "No local reference point of last backup. Exiting."
        exit 4
    fi

    if [[ "$backing" != "$base" ]]; then
        >&2 echo "Invalid state. The backing chain of $file is longer than one."
        exit 5
    fi
    
    $VERBOSE && echo "Disk target $target, $backing."
    $VERBOSE && qemu-img info "$backing" | grep "virtual size"
    $VERBOSE && echo "Waiting for local/remote md5 calculation"

    if $VERBOSE; then
        STATUS="progress"
    else
        STATUS="none"
    fi

    local_checksum="$(mktemp)"
    /sbin/modprobe nbd; qemu-nbd -d $NBDDEV > /dev/null
    qemu-nbd -r -c $NBDDEV "$backing"
    dd if=$NBDDEV bs=64K status=$STATUS | md5sum | cut -f 1 -d ' ' > "$local_checksum" &

    remote_checksum="$(mktemp)"
    ssh -n $BACKUP_HOST "/sbin/modprobe nbd; qemu-nbd -d $NBDDEV > /dev/null"
    ssh -n $BACKUP_HOST "qemu-nbd -r -c $NBDDEV $BACKUP_FOLDER/$(basename $file)"
    ssh -n $BACKUP_HOST "dd if=$NBDDEV bs=64K status=$STATUS | md5sum | cut -f 1 -d ' '" > "$remote_checksum" &

    wait

    echo "$BACKUP_HOST:$BACKUP_FOLDER/$(basename $file)" $(cat "$remote_checksum")
    echo "$(hostname -f):$backing" $(cat "$local_checksum")

    qemu-nbd -d $NBDDEV > /dev/null
    ssh -n $BACKUP_HOST "qemu-nbd -d $NBDDEV > /dev/null"

    if ! diff -q "$local_checksum" "$remote_checksum" > /dev/null; then
        >&2 echo ERROR: "Checksums do not match"
        >&2 echo ERROR: "$BACKUP_HOST:$BACKUP_FOLDER/$(basename $file)" $(cat "$remote_checksum")
        >&2 echo ERROR: "$(hostname -f):$backing" $(cat "$local_checksum")
        exit 6
    fi

    rm -f "$local_checksum" "$remote_checksum"

done
