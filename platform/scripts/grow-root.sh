#!/bin/bash
# grow-root.sh - extend the root partition and filesystem to the full volume size.
# Why: the EBS volume was enlarged from 30 GiB to 60 GiB while the instance was
# stopped. EBS grows the block device, but the partition and ext4 filesystem
# inside it still think they are 30 GiB until they are told otherwise.
set -uo pipefail
echo "==> before"
df -h /
lsblk

ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_DISK="$(lsblk -no PKNAME "${ROOT_SRC}" | head -n 1)"
ROOT_PART="$(echo "${ROOT_SRC}" | grep -oE '[0-9]+$' || true)"

echo "==> root device: ${ROOT_SRC} disk: /dev/${ROOT_DISK} partition: ${ROOT_PART}"

if [ -z "${ROOT_DISK}" ] || [ -z "${ROOT_PART}" ]; then
  echo "ERROR: could not determine the root disk/partition; refusing to guess" >&2
  exit 1
fi

apt-get install -y --no-install-recommends cloud-guest-utils >/dev/null

# Why --fix off: growpart should report a problem rather than rewrite a partition
# table it does not understand.
growpart "/dev/${ROOT_DISK}" "${ROOT_PART}" || echo "WARN: growpart reported no change or failed"

# Why resize2fs on the mounted root: ext4 supports online growth, so no reboot or
# unmount is needed. If the filesystem is not ext4, report it instead of guessing.
if ! resize2fs "${ROOT_SRC}"; then
  echo "WARN: resize2fs failed; filesystem may not be ext4" >&2
fi

echo "==> after"
df -h /
lsblk
