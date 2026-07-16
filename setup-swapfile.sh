#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Elevating privileges (sudo)..."
  exec sudo bash "$0" "$@"
fi

mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
default_size_gib=$(((mem_total_kb + 1048575) / 1048576))

read -r -p "Enter swap file size in GiB [Default: ${default_size_gib}]: " user_input

if [ -z "${user_input}" ]; then
  swap_size_gib=${default_size_gib}
elif [[ ! "${user_input}" =~ ^[0-9]+$ ]] || [ "${user_input}" -le 0 ]; then
  echo "Error: Invalid size. Please enter a positive integer." >&2
  exit 1
else
  swap_size_gib="${user_input}"
fi

echo "Setting up a ${swap_size_gib}GiB swapfile..."

# 0. Cleanup handler: always release the top-level mount and any leftover temp fstab file
FSTAB_TMP=""
cleanup() {
  local ec=$?
  [ -n "${FSTAB_TMP}" ] && rm -f "${FSTAB_TMP}"
  umount /mnt/topsetup 2>/dev/null || true
  exit "${ec}"
}
trap cleanup EXIT

# 1. Root Device UUID & Top-level (ID=5) Environment Setup
ROOT_DEV_UUID=$(findmnt -no UUID /)
ROOT_DEV="/dev/disk/by-uuid/${ROOT_DEV_UUID}"

mkdir -p /mnt/topsetup
mount -o subvolid=5 "${ROOT_DEV}" /mnt/topsetup

# 2. Create @swap subvolume on top-level (ID=5) to survive rollbacks
if [ ! -d /mnt/topsetup/@swap ]; then
  echo "Creating independent @swap subvolume on top-level (ID=5)..."
  btrfs subvolume create /mnt/topsetup/@swap
fi

# 3. Mount top-level @swap subvolume to current root /@swap path
mkdir -p /@swap
if ! mountpoint -q /@swap; then
  mount -o subvol=/@swap "${ROOT_DEV}" /@swap
fi

# 4. Handle active swap spaces and clean up legacy /swapfile safely
if swapon --show --noheadings | awk '{print $1}' | grep -q -x '/swapfile'; then
  swapoff /swapfile
fi
[ -f /swapfile ] && rm -f /swapfile

# 5. Allocate physical swapfile ONLY IF it does not exist (Prevents TBW wear)
if [ ! -f /@swap/swapfile ]; then
  echo "Allocating physical, contiguous swapfile (One-time operation)..."
  btrfs filesystem mkswapfile --size "${swap_size_gib}g" /@swap/swapfile
else
  echo "Existing swapfile found. Reusing it to protect disk lifespan."
fi

# 6. Activate swap space safely
swapon --show --noheadings | awk '{print $1}' | grep -q -x '/@swap/swapfile' || swapon /@swap/swapfile

# 7. Restructure fstab entries to use absolute subvolume targeting
FSTAB_PATH="/etc/fstab"
FSTAB_TMP=$(mktemp "${FSTAB_PATH}.XXXXXX")

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    echo "$line" >>"${FSTAB_TMP}"
    continue
  fi

  device=$(awk '{print $1}' <<<"$line")
  mount_point=$(awk '{print $2}' <<<"$line")
  fstype3=$(awk '{print $3}' <<<"$line")

  if [ "${mount_point}" = "/@swap" ]; then
    continue
  fi
  if [ "${fstype3}" = "swap" ] && { [ "${device}" = "/swapfile" ] || [ "${device}" = "/@swap/swapfile" ]; }; then
    continue
  fi

  echo "$line" >>"${FSTAB_TMP}"
done <"${FSTAB_PATH}"

echo -e "/dev/disk/by-uuid/${ROOT_DEV_UUID}\t/@swap\tbtrfs\tsubvol=/@swap,defaults,noatime\t0\t0" >>"${FSTAB_TMP}"
echo -e "/@swap/swapfile\tnone\tswap\tdefaults\t0\t0" >>"${FSTAB_TMP}"

chmod 644 "${FSTAB_TMP}"
mv "${FSTAB_TMP}" "${FSTAB_PATH}"
FSTAB_TMP=""
systemctl daemon-reload

echo "--- Current Swap Status ---"
swapon --show
free -h
