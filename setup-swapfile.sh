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
  swap_size_gib=$((user_input))
fi

echo "Setting up a ${swap_size_gib}GiB swapfile..."

<<<<<<< HEAD
# 0. Cleanup handler: always release the top-level mount and any leftover
#    temp fstab file, on both success and failure. (The previous script used
#    `trap ... RETURN`, which never fires for a top-level script — only
#    inside functions/sourced files — so the temp fstab file was never
#    actually cleaned up on early exit.)
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
=======
# 1. Root Device UUID & Top-level (ID=5) Environment Setup
ROOT_DEV_UUID=$(findmnt -no UUID /)
ROOT_DEV="/dev/disk/by-uuid/${ROOT_DEV_UUID}"

mkdir -p /mnt/topsetup
mount -o subvolid=5 "${ROOT_DEV}" /mnt/topsetup
trap 'umount /mnt/topsetup 2>/dev/null || true' EXIT

# 2. Create @swap subvolume on top-level (ID=5) to survive rollbacks
if [ ! -d /mnt/topsetup/@swap ]; then
  echo "Creating independent @swap subvolume on top-level (ID=5)..."
  btrfs subvolume create /mnt/topsetup/@swap
fi

# 3. Handle active swap spaces and clean up legacy /swapfile
if swapon --show --noheadings | awk '{print $1}' | grep -q -x '/swapfile'; then
  sudo swapoff /swapfile
fi
[ -f /swapfile ] && rm /swapfile

# 4. Restructure fstab entries to use absolute subvolume targeting
FSTAB_PATH="/etc/fstab"
FSTAB_TMP=$(mktemp)
trap 'rm -f "${FSTAB_TMP}"' RETURN

while IFS= read -r line || [ -n "$line" ]; do
  # Clean up legacy swap and relative path entries
  if [[ "$line" =~ ^[[:space:]]*# ]] ||
    { [[ "$line" != *"/@swap"* ]] && [[ "$line" != *"/swapfile"* ]] &&
      [[ "$(echo "$line" | awk '{print $3}')" != "swap" ]]; }; then
    echo "$line" >>"${FSTAB_TMP}"
  fi
done <"${FSTAB_PATH}"

# Inject absolute Btrfs subvolume fstab mapping rule
echo -e "UUID=${ROOT_DEV_UUID}\t/@swap\tbtrfs\tdefaults,noatime,subvol=/@swap\t0\t0" >>"${FSTAB_TMP}"
echo -e "/@swap/swapfile\tnone\tswap\tdefaults\t0\t0" >>"${FSTAB_TMP}"

cat "${FSTAB_TMP}" >"${FSTAB_PATH}"

# [교정] fstab 반영 직후 즉시 데몬 리로드하여 힌트 메시지 원천 차단
systemctl daemon-reload

# 5. Mount top-level @swap subvolume to current root /@swap path
mkdir -p /@swap
if ! mountpoint -q /@swap; then
  mount -o subvol=/@swap "${ROOT_DEV}" /@swap
fi

# 6. Allocate physical swapfile ONLY IF it does not exist (Prevents TBW wear)
>>>>>>> 42fea1355c9b945c387b4a77235da38b1da37647
if [ ! -f /@swap/swapfile ]; then
  echo "Allocating physical, contiguous swapfile (One-time operation)..."
  btrfs filesystem mkswapfile --size "${swap_size_gib}g" /@swap/swapfile
else
  echo "Existing swapfile found. Reusing it to protect disk lifespan."
fi

<<<<<<< HEAD
# 6. Activate swap space safely
# (Fixed: the previous check compared against the raw `swapon --show` line,
#  which includes TYPE/SIZE/USED/PRIO columns and a header, so the exact
#  match could never succeed. That meant this line would always try to
#  swapon an already-active swapfile on a second run and fail under
#  `set -e`. Now matches step 4's pattern: --noheadings + first column only.)
swapon --show --noheadings | awk '{print $1}' | grep -q -x '/@swap/swapfile' || swapon /@swap/swapfile

# 7. Restructure fstab entries to use absolute subvolume targeting
FSTAB_PATH="/etc/fstab"
FSTAB_TMP=$(mktemp)

# (Fixed: the previous filter dropped any line containing "/@swap" or
#  "/swapfile" as a substring anywhere, or any line whose 3rd field was
#  "swap" — which would also silently delete unrelated entries, e.g. a
#  separate swap partition. Now it only drops the exact /@swap mount line
#  and swap entries pointing specifically at our own swapfile paths.)
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

cat "${FSTAB_TMP}" >"${FSTAB_PATH}"
rm -f "${FSTAB_TMP}"
FSTAB_TMP=""
systemctl daemon-reload
=======
# 7. Activate swap space safely
swapon --show | grep -q '/@swap/swapfile' || swapon /@swap/swapfile

# 8. Finalize configuration
umount /mnt/topsetup
trap - EXIT
>>>>>>> 42fea1355c9b945c387b4a77235da38b1da37647

echo "--- Current Swap Status ---"
swapon --show
free -h
