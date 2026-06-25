#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Elevating privileges (sudo)..."
  exec sudo bash "$0" "$@"
fi

#################################################
# PART 1: Separate root subvolume from snapshot tree
#################################################

FSTAB_PATH="/etc/fstab"
FSTAB_BACKUP="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

cp "$FSTAB_PATH" "$FSTAB_BACKUP"
echo "fstab backup created at $FSTAB_BACKUP"

ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
echo "Root device: $ROOT_DEV"

mkdir -p /mnt/topsetup
mount -o subvolid=5 "$ROOT_DEV" /mnt/topsetup

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

TEMP_FSTAB=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
  if [[ ! "$line" =~ ^[[:space:]]*# ]] && echo "$line" | awk '{print $3}' | grep -q "^btrfs$"; then
    current_options=$(echo "$line" | awk '{print $4}')
    new_options="$current_options"

    if [[ "$new_options" != *noatime* ]]; then
      new_options="${new_options:+$new_options,}noatime"
    fi

    if [[ "$new_options" == *compress=* ]]; then
      new_options=$(echo "$new_options" | sed -E 's/compress=[a-z0-9:]+/compress=zstd/')
    else
      new_options="${new_options:+$new_options,}compress=zstd"
    fi

    updated_line="${line/"$current_options"/"$new_options"}"
    echo "$updated_line" >>"$TEMP_FSTAB"
  else
    echo "$line" >>"$TEMP_FSTAB"
  fi
done <"$FSTAB_PATH"

if ! grep -qE '\s+/\.snapshots\s' "$TEMP_FSTAB"; then
  echo -e "${ROOT_DEV}\t/.snapshots\tbtrfs\tsubvol=/.snapshots,defaults,noatime,compress=zstd\t0\t0" >>"$TEMP_FSTAB"
fi

mv "$TEMP_FSTAB" "$FSTAB_PATH"
chmod 644 "$FSTAB_PATH"

echo "Reloading systemd manager configuration..."
systemctl daemon-reload

echo "Applying new mount options..."
if ! mount -a; then
  echo "mount -a failed! Restoring fstab from backup."
  cp "$FSTAB_BACKUP" "$FSTAB_PATH"
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

CONFIG_NAME="root"
CONFIG_PATH="/etc/snapper/configs/$CONFIG_NAME"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Creating snapper configuration for root..."
  snapper -c "$CONFIG_NAME" create-config /
else
  echo "Snapper configuration for root already exists. Skipping creation."
fi

CONFIG_BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG_PATH" "$CONFIG_BACKUP"
echo "Snapper config backed up to $CONFIG_BACKUP"

set_config_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$CONFIG_PATH"; then
    sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$CONFIG_PATH"
  else
    echo "${key}=\"${value}\"" >>"$CONFIG_PATH"
  fi
}

echo "Configuring timeline snapshot retention..."
set_config_value "TIMELINE_CREATE" "yes"
set_config_value "TIMELINE_LIMIT_HOURLY" "6"
set_config_value "TIMELINE_LIMIT_DAILY" "7"
set_config_value "TIMELINE_LIMIT_WEEKLY" "4"
set_config_value "TIMELINE_LIMIT_MONTHLY" "0"
set_config_value "TIMELINE_LIMIT_YEARLY" "0"

echo "Configuring number-based cleanup for apt/boot snapshots..."
set_config_value "NUMBER_CLEANUP" "yes"
set_config_value "NUMBER_LIMIT" "50"
set_config_value "NUMBER_LIMIT_IMPORTANT" "10"

HOOK_PATH="/etc/apt/apt.conf.d/80snapper"
STATE_FILE="/run/snapper-apt-pre-number"
echo "Creating APT hook for Snapper at $HOOK_PATH..."
cat <<EOF >"$HOOK_PATH"
DPkg::Pre-Invoke {"[ -x /usr/bin/snapper ] && /usr/bin/snapper -c root create --print-number -t pre -d 'APT Pre-Invoke' > ${STATE_FILE} 2>/dev/null || true";};
DPkg::Post-Invoke {"[ -x /usr/bin/snapper ] && [ -f ${STATE_FILE} ] && /usr/bin/snapper -c root create -d 'APT Post-Invoke' -t post --pre-number=\$(cat ${STATE_FILE}) || true";};
EOF
chmod 644 "$HOOK_PATH"

echo "Creating systemd service for boot snapshots..."
SERVICE_PATH="/etc/systemd/system/snapper-boot.service"
cat <<'EOF' >"$SERVICE_PATH"
[Unit]
Description=Take Snapper Snapshot on Boot
After=local-fs.target
ConditionPathExists=/etc/snapper/configs/root

[Service]
Type=oneshot
ExecStart=/usr/bin/snapper -c root create -d "Boot Snapshot"

[Install]
WantedBy=default.target
EOF
chmod 644 "$SERVICE_PATH"

echo "Enabling services and timers..."
systemctl daemon-reload
systemctl enable snapper-boot.service
systemctl enable --now snapper-timeline.timer
systemctl enable --now snapper-cleanup.timer

echo "Creating initial verification snapshot..."
snapper -c "$CONFIG_NAME" create -d "Initial automated setup"

#################################################
# PART 4: Final verification
#################################################

echo "--- Current Snapper Snapshots ---"
snapper -c "$CONFIG_NAME" list

echo "--- Snapper config ($CONFIG_PATH) ---"
grep -E '^(TIMELINE|NUMBER)_' "$CONFIG_PATH"

if [ "$ROOT_SEPARATED" -eq 1 ]; then
  echo ""
  echo "Root subvolume was separated. Reboot now to apply independent structures."
  echo "After reboot, verify with: cat /proc/cmdline and sudo btrfs subvolume get-default /"
fi

echo "Setup complete: clean root separation layout established without grub overrides."
