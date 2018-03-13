#!/bin/bash

BACKUP_HOST="$1"
BACKUP_FOLDER="$2"
MAX_BACKUPS="${3:-7}"
TMPDIR="${4:-$TMPDIR}"
TMPDIR="${TMPDIR:-/tmp}"

export LIBVIRT_DEFAULT_URI="qemu:///system"

if [ -z "$BACKUP_HOST" -o -z "$BACKUP_FOLDER" ]; then
    >&2 echo "Usage: $(basename $0) <backup-host> <backup-folder> [max-backups] [tmpdir]"
    exit 1
fi

virsh list --all --name | while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    $(dirname "$0")/vm-backup-inc.sh "$domain" "$BACKUP_HOST" "$BACKUP_FOLDER" "$MAX_BACKUPS" "$TMPDIR"
    echo
done

comm -23 <(ssh "$BACKUP_HOST" ls "$BACKUP_FOLDER" | sort) <(virsh list --all --name | sort) | while IFS= read -r unknown; do
    >&2 echo "Unknown folder on backup host $BACKUP_HOST:$BACKUP_FOLDER/$unknown"
done
