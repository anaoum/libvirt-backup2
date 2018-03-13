# QEMU/libvirt Backup Scripts

A collection of scripts to be used with QEMU/libvirt that facilitate incremental backing up of running virtual machines to a remote server. At the moment, only file backed devices are supported.

To install, the files need to be copied to /usr/local/bin on the host:
```
chmod +x *.sh
cp *.sh /usr/local/bin
```

`qemu-img` needs to be available on the remote server. On Debian based machines, this can be installed with:
```
sudo apt install qemu-utils
```

To enable incremental backups of all running virtual machines at midnight every day, execute:
```
echo '0 0 * * * root /usr/local/bin/vm-backup-inc-all.sh HOST REMOTE_DIR' > /etc/cron.d/backup-vms
```

By default, a maximum of 7 incremental backups are kept.
