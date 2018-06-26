#!/bin/bash

set -e

DOMAIN="$1"
BACKUP_HOST="$2"
BACKUP_FOLDER="$3"
MAX_BACKUPS="${4:-7}"
TMPDIR="${5:-$TMPDIR}"
TMPDIR="${TMPDIR:-/tmp}"

if [ -z "$DOMAIN" -o -z "$BACKUP_HOST" -o -z "$BACKUP_FOLDER" ]; then
    >&2 echo "Usage: $(basename $0) <domain> <backup-host> <backup-folder> [max-backups] [tmpdir]"
    exit 1
fi

export LIBVIRT_DEFAULT_URI="qemu:///system"

if ! virsh dominfo "$DOMAIN" > /dev/null 2>&1; then
    >&2 echo "Domain '$DOMAIN' does not exist."
    exit 2
fi

if ! virsh dominfo "$DOMAIN" | grep -q 'State:\s*running'; then
    >&2 echo "Domain '$DOMAIN' is not running, cannot perform incremental backup."
    exit 3
fi

echo "Backing up domain $DOMAIN."

BACKUP_FOLDER="$BACKUP_FOLDER/$DOMAIN"

SNAPSHOT_NAME="$(date '+%Y%m%d%H%M%S')"
echo "The snapshot will be timestamped $SNAPSHOT_NAME."

echo "Creating $BACKUP_FOLDER on $BACKUP_HOST"
ssh -n "$BACKUP_HOST" mkdir -p "$BACKUP_FOLDER"

echo "Saving XML to $BACKUP_HOST:$BACKUP_FOLDER/$DOMAIN.xml"
virsh dumpxml "$DOMAIN" | ssh "$BACKUP_HOST" "cat - > $BACKUP_FOLDER/$DOMAIN.xml"

function get_backing() {
    qemu-img info -U "$1" | sed -n 's/^backing file: //p'
}
function get_backing_chain() {
    qemu-img info -U --backing-chain "$1" | sed -n 's/^image: //p'
}
function get_chain_base() {
    get_backing_chain "$1" | tail -1
}

echo "$DOMAIN is running, will use libvirt commands."

if virsh domfsthaw "$1" >/dev/null 2>&1; then
    QUIESCE="--quiesce"
    echo "QEMU agent is available on $DOMAIN, will request a quiesce."
else
    QUIESCE=""
fi

DISKSPEC="$(
virsh domblklist "$DOMAIN" --details | sed -n 's/^file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | while IFS=: read -r target file; do
    base="$(get_chain_base "$file")"
    if [[ "$base" == *"nobackup"* ]]; then
        echo -n " --diskspec $target,snapshot=no"
    else
        snapshot="${base/.qcow2/.$SNAPSHOT_NAME.qcow2}"
        echo -n " --diskspec $target,snapshot=external,file=$snapshot"
    fi
done
)"

/usr/sbin/aa-complain "/etc/apparmor.d/libvirt/libvirt-$(virsh domuuid "$DOMAIN" | grep -v '^$')"
virsh snapshot-create-as --domain "$DOMAIN" --no-metadata --atomic $QUIESCE --disk-only $DISKSPEC
/usr/sbin/aa-enforce "/etc/apparmor.d/libvirt/libvirt-$(virsh domuuid "$DOMAIN" | grep -v '^$')"

virsh domblklist "$DOMAIN" --details | sed -n 's/^file *disk *\([^ ]*\) *\(.*\)/\1:\2/p' | while IFS=: read -r target file; do
    base="$(get_chain_base "$file")"
    if [[ "$base" == *"nobackup"* ]]; then
        continue
    fi
    backing="$(get_backing "$file")"

    compacted="$(mktemp -p "$TMPDIR")"
    echo "Converting $backing to $compacted to minimize data transfer."
    if [[ "$base" == "$backing" ]]; then
        qemu-img convert -O qcow2 "$backing" "$compacted"
    else
        qemu-img convert -O qcow2 "$backing" -B "$(get_backing "$backing")" "$compacted"
    fi
    echo "Copying $compacted to $BACKUP_HOST:$BACKUP_FOLDER/$(basename "$file")"
    scp "$compacted" $BACKUP_HOST:"$BACKUP_FOLDER/$(basename "$file")"
    echo "Deleting $compacted."
    rm -f "$compacted"

    if [[ "$base" != "$backing" ]]; then
        echo "Committing "$backing" down to $base."
        virsh blockcommit "$DOMAIN" $target --top "$backing" --wait | grep -v '^$'
        echo "Deleting "$backing"."
        rm -f "$backing"
        echo "Rebasing $BACKUP_HOST:"$BACKUP_FOLDER/$(basename "$file")" to be based on $BACKUP_HOST:"$BACKUP_FOLDER/$(basename "$backing")""
        ssh -n $BACKUP_HOST qemu-img rebase -u -b "$BACKUP_FOLDER/$(basename "$backing")" "$BACKUP_FOLDER/$(basename "$file")"
    fi

    remote_chain="$(ssh -n $BACKUP_HOST qemu-img info -U --backing-chain "$BACKUP_FOLDER/$(basename "$file")" | sed -n 's/^image: //p')"
    while [ $(echo -n "$remote_chain" | wc -l) -gt "$MAX_BACKUPS" ]; do
        echo "There are currently $(echo -n "$remote_chain" | wc -l) backups, more than the allowed $MAX_BACKUPS."
        oldbase="$(echo -n "$remote_chain" | tail -1)"
        newbase="$(echo -n "$remote_chain" | tail -2 | head -1)"
        echo "Committing $newbase down to $oldbase"
        ssh -n $BACKUP_HOST qemu-img commit -d "$newbase"
        echo "Moving "$oldbase" to "$newbase"."
        ssh -n $BACKUP_HOST mv "$oldbase" "$newbase"
        remote_chain="$(ssh -n $BACKUP_HOST qemu-img info -U --backing-chain "$BACKUP_FOLDER/$(basename "$file")" | sed -n 's/^image: //p')"
    done
done
