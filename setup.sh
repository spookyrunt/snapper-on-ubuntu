#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Elevating privileges (sudo)..."
  exec sudo bash "$0" "$@"
fi

#################################################
# PART 1: Separate root subvolume from snapshot tree
#################################################

ROOT_DEV=$(findmnt -no UUID /)
ROOT_DEV="/dev/disk/by-uuid/${ROOT_DEV}"
echo "Root device: $ROOT_DEV"

mkdir -p /mnt/topsetup
mount -o subvolid=5 "$ROOT_DEV" /mnt/topsetup
trap 'umount /mnt/topsetup 2>/dev/null || true' EXIT

CURRENT_DEFAULT_PATH=$(btrfs subvolume get-default / | awk '{print $NF}')
NEW_ROOT_NAME="@"

if [[ "$CURRENT_DEFAULT_PATH" == *".snapshots/"* ]]; then
  echo "Current root is inside a snapshot path. Separating it."
  SRC_PATH="/mnt/topsetup/${CURRENT_DEFAULT_PATH#<FS_TREE>/}"

  if [ -d "/mnt/topsetup/${NEW_ROOT_NAME}" ]; then
    echo "${NEW_ROOT_NAME} already exists but is stale after a rollback. Replacing it."
    btrfs subvolume delete "/mnt/topsetup/${NEW_ROOT_NAME}"
  fi
  btrfs subvolume snapshot "$SRC_PATH" "/mnt/topsetup/${NEW_ROOT_NAME}"

  NEW_ID=$(btrfs subvolume list /mnt/topsetup | grep "path ${NEW_ROOT_NAME}$" | awk '{print $2}')
  btrfs subvolume set-default "$NEW_ID" /mnt/topsetup
  echo "Default subvolume set to ${NEW_ROOT_NAME} (ID ${NEW_ID})."
  ROOT_SEPARATED=1
else
  echo "Already an independent subvolume structure. No change."
  ROOT_SEPARATED=0
fi

umount /mnt/topsetup

#################################################
# PART 2: Normalize fstab options (noatime, compress=zstd)
#################################################

FSTAB_BACKUP="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/fstab "$FSTAB_BACKUP"
echo "fstab backup created at $FSTAB_BACKUP"

TEMP_FSTAB=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
  if [[ ! "$line" =~ ^[[:space:]]*# ]] && echo "$line" | awk '{print $3}' | grep -q "^btrfs$"; then
    current_options=$(echo "$line" | awk '{print $4}')
    new_options="$current_options"

    if [[ "$new_options" != *noatime* ]]; then
      new_options="${new_options:+$new_options,}noatime"
    fi

    if [[ "$new_options" == *compress-force=* ]]; then
      new_options=$(echo "$new_options" | sed -E 's/compress-force=[a-z0-9:]+/compress-force=zstd/')
    elif [[ "$new_options" == *compress=* ]]; then
      new_options=$(echo "$new_options" | sed -E 's/compress=[a-z0-9:]+/compress=zstd/')
    else
      new_options="${new_options:+$new_options,}compress=zstd"
    fi

    updated_line="${line/"$current_options"/"$new_options"}"
    echo "$updated_line" >>"$TEMP_FSTAB"
  else
    echo "$line" >>"$TEMP_FSTAB"
  fi
done </etc/fstab

if ! grep -qE '\s+/\.snapshots\s' "$TEMP_FSTAB"; then
  echo -e "${ROOT_DEV}\t/.snapshots\tbtrfs\tsubvol=/.snapshots,defaults,noatime,compress=zstd\t0\t0" >>"$TEMP_FSTAB"
fi

mv "$TEMP_FSTAB" /etc/fstab
chmod 644 /etc/fstab
echo "Reloading systemd manager configuration..."
systemctl daemon-reload

echo "Applying new mount options..."
if ! mount -a; then
  echo "mount -a failed! Restoring fstab from backup."
  cp "$FSTAB_BACKUP" /etc/fstab
  systemctl daemon-reload
  exit 1
fi

echo "--- Current Btrfs Mount Status ---"
mount | grep btrfs

#################################################
# PART 3: Install and configure snapper
#################################################

echo "Installing snapper..."
apt update
apt install -y snapper

echo "Configuring Snapper..."
[ -f /etc/snapper/configs/root ] || snapper -c root create-config /
snapper -c root set-config \
  TIMELINE_CREATE=yes \
  TIMELINE_CLEANUP=yes \
  TIMELINE_LIMIT_HOURLY=2 \
  TIMELINE_LIMIT_DAILY=2 \
  TIMELINE_LIMIT_WEEKLY=2 \
  TIMELINE_LIMIT_MONTHLY=1 \
  TIMELINE_LIMIT_YEARLY=0 \
  NUMBER_CLEANUP=yes \
  NUMBER_LIMIT=5 \
  NUMBER_LIMIT_IMPORTANT=5

echo "Creating APT hook for Snapper..."
cat >/etc/apt/apt.conf.d/80snapper <<EOF
DPkg::Pre-Invoke {"[ -x /usr/bin/snapper ] && /usr/bin/snapper -c root create --print-number -t pre --cleanup-algorithm number -d 'APT Pre-Invoke' > /run/snapper-apt-pre-number 2>/dev/null || true";};
DPkg::Post-Invoke {"[ -x /usr/bin/snapper ] && [ -f /run/snapper-apt-pre-number ] && /usr/bin/snapper -c root create --cleanup-algorithm number -d 'APT Post-Invoke' -t post --pre-number=\$(cat /run/snapper-apt-pre-number) || true";};
EOF
chmod 644 /etc/apt/apt.conf.d/80snapper

echo "Enabling Snapper timers..."
systemctl daemon-reload
systemctl enable snapper-boot.timer
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer

echo "Creating initial verification snapshot..."
snapper -c root create -d "Initial automated setup"

#################################################
# PART 4: Final verification
#################################################

echo "--- Current Snapper Snapshots ---"
snapper -c root list

echo "--- Snapper config (/etc/snapper/configs/root) ---"
grep -E '^(TIMELINE|NUMBER)_' /etc/snapper/configs/root

if [ "$ROOT_SEPARATED" -eq 1 ]; then
  echo ""
  echo "Root subvolume was separated. Reboot now to apply independent structures."
  echo "After reboot, verify with: cat /proc/cmdline and sudo btrfs subvolume get-default /"
fi

echo "Setup complete: clean root separation layout established without grub overrides."
