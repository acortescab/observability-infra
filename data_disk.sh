#!/bin/bash
set -euxo pipefail

# --- Data disk (first part of user_data) ---
# Mounts the separate EBS data volume on /var/lib/docker before Docker is installed, so the telemetry never
# lands on the root disk. Terraform attaches the volume after launching the instance: wait for it to show up.
# Only formats a blank disk, so a volume that already holds data (a replaced host) is reused as it is.
DEV="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id}"
MOUNT_POINT=/var/lib/docker

for _ in $(seq 1 60); do
  [ -b "$DEV" ] && break
  sleep 5
done
[ -b "$DEV" ] || { echo "Data volume $DEV did not attach in time" >&2; exit 1; }

blkid "$DEV" || mkfs.ext4 -L obs-data "$DEV"

mkdir -p "$MOUNT_POINT"
echo "UUID=$(blkid -s UUID -o value "$DEV") $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
mount "$MOUNT_POINT"

# nofail alone would let Docker start on the root disk if the mount ever fails: make Docker wait for it.
install -d /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT_POINT" > /etc/systemd/system/docker.service.d/data-disk.conf
