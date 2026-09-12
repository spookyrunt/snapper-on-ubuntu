#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

SILENT=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--silent" ]; then
    SILENT=1
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

usage() {
  echo "Usage: rollback <snapshot-number> [--silent]"
  echo "       rollback --finish [--silent]   (manual cleanup, only needed if auto-finish failed)"
  echo "       rollback --auto-finish         (used internally by the systemd unit)"
  echo "Run 'sudo snapper list' to see available snapshot numbers."
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ $# -gt 1 ]; then
  echo "Error: unexpected extra argument(s): ${*:2}"
  usage
  exit 1
fi

if [ "$1" != "--auto-finish" ] && [ "$SILENT" -ne 1 ]; then
  TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
  LOG_FILE="/var/log/rollback_${TIMESTAMP}.log"
  exec > >(tee -i "$LOG_FILE") 2>&1
  echo "=== Rollback Script Started ==="
  echo "$LOG_FILE $(date '+%Y-%m-%d %H:%M:%S')"
  echo "================================"
fi

INSTALL_PATH="/usr/local/bin/rollback"
SCRIPT_REAL=$(realpath "$0")
if [ "$SCRIPT_REAL" != "$INSTALL_PATH" ]; then
  cp "$SCRIPT_REAL" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
fi

AUTOFINISH_SERVICE="/etc/systemd/system/rollback-finish.service"
ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*\]//')

# @oldtrash existing means a previous swap hasn't been cleaned up yet.
# btrfs subvolume list works against any mount of the filesystem, so this
# doesn't need a separate top-level mount.
oldtrash_exists() {
  btrfs subvolume list / | grep -q "path @oldtrash\$"
}

# Deletes @oldtrash left over from the last swap. No grub/update-grub here:
# the name "@" never changes, so GRUB's config and search path stay valid
# across rollbacks without touching them.
do_finish() {
  echo "Step 1: mounting top-level subvolume..."
  mkdir -p /mnt/toprollback
  mount -o subvolid=5 "$ROOT_DEV" /mnt/toprollback

  echo "Step 2: deleting @oldtrash..."
  # Defensive: if a crashed run left @oldtrash marked as default,
  # btrfs refuses to delete it until default points elsewhere.
  CURRENT_ID=$(btrfs subvolume show / | awk '/Subvolume ID:/{print $NF}')
  btrfs subvolume set-default "$CURRENT_ID" /mnt/toprollback
  if ! btrfs subvolume delete "/mnt/toprollback/@oldtrash"; then
    echo "Warning: failed to delete @oldtrash (likely disk full). Run 'rollback --finish' later."
  fi

  echo "Step 3: unmounting top-level subvolume..."
  umount /mnt/toprollback

  echo "Step 4: updating GRUB bootloader to pin rootflags=subvol=@ so booting no longer depends on btrfs default..."
  # Executing update-grub here regenerates /boot/grub/grub.cfg with rootflags=subvol=@.
  # However, GRUB will NOT read this file during boot UNLESS grub-install is run
  # to update the early config (/boot/efi/EFI/ubuntu/grub.cfg), aligning the prefix
  # path from '($root)/boot/grub' to '($root)/@/boot/grub' so that GRUB parses the updated grub.cfg.
  update-grub
  grub-install
}

cleanup_autofinish_service() {
  systemctl disable rollback-finish.service >/dev/null 2>&1 || true
  rm -f "$AUTOFINISH_SERVICE"
  systemctl daemon-reload
}

if [ "$1" = "--auto-finish" ]; then
  if ! oldtrash_exists; then
    cleanup_autofinish_service
    exit 0
  fi
  do_finish
  cleanup_autofinish_service
  echo "Auto-finish complete. @oldtrash cleaned up."
  exit 0
fi

if [ "$1" = "--finish" ]; then
  if ! oldtrash_exists; then
    echo "Nothing to finish (@oldtrash not found)."
    exit 0
  fi
  do_finish
  cleanup_autofinish_service
  echo ""
  echo "Finished. @oldtrash cleaned up."
  echo "Verify with: cat /proc/cmdline"
  exit 0
fi

TARGET_NUMBER="$1"

if oldtrash_exists; then
  echo "Error: a previous rollback isn't finished yet (@oldtrash exists)."
  echo "Reboot to let auto-finish run, or run: rollback --finish"
  exit 1
fi

SNAPSHOT_PATH="/.snapshots/${TARGET_NUMBER}/snapshot"
if [ ! -d "$SNAPSHOT_PATH" ]; then
  echo "Error: snapshot ${TARGET_NUMBER} not found at ${SNAPSHOT_PATH}."
  echo "Run 'sudo snapper list' to check available snapshot numbers."
  exit 1
fi

echo "Step 1: backing up current root (@) as a read-only snapshot..."
snapper create -d "pre-rollback backup before switching to #${TARGET_NUMBER}" -c number

echo "Step 2: mounting top-level subvolume..."
mkdir -p /mnt/toprollback
mount -o subvolid=5 "$ROOT_DEV" /mnt/toprollback

echo "Step 3: removing any stale @tmp from a previous incomplete run..."
if [ -d "/mnt/toprollback/@tmp" ]; then
  btrfs subvolume delete "/mnt/toprollback/@tmp"
fi

echo "Step 4: creating @tmp from the content of snapshot ${TARGET_NUMBER}..."
btrfs subvolume snapshot "/mnt/toprollback/.snapshots/${TARGET_NUMBER}/snapshot" "/mnt/toprollback/@tmp"

echo "Step 5: installing auto-finish helper inside @tmp..."
mkdir -p "/mnt/toprollback/@tmp/usr/local/bin"
cp "$SCRIPT_REAL" "/mnt/toprollback/@tmp${INSTALL_PATH}"
chmod +x "/mnt/toprollback/@tmp${INSTALL_PATH}"

mkdir -p "/mnt/toprollback/@tmp/etc/systemd/system/multi-user.target.wants"
cat <<EOF >"/mnt/toprollback/@tmp/etc/systemd/system/rollback-finish.service"
[Unit]
Description=Finish pending btrfs rollback (one-shot, self-disabling)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --auto-finish

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "/mnt/toprollback/@tmp/etc/systemd/system/rollback-finish.service"
ln -sf "../rollback-finish.service" \
  "/mnt/toprollback/@tmp/etc/systemd/system/multi-user.target.wants/rollback-finish.service"

echo "Step 6: swapping content into @ (name '@' never changes)..."
# Not atomic: for the instant between these two mv's, nothing is named
# "@". A crash/power-loss exactly here needs a live-USB to fix.
mv "/mnt/toprollback/@" "/mnt/toprollback/@oldtrash"
mv "/mnt/toprollback/@tmp" "/mnt/toprollback/@"
NEW_ID=$(btrfs subvolume list /mnt/toprollback | grep "path @\$" | awk '{print $2}')
btrfs subvolume set-default "$NEW_ID" /mnt/toprollback

echo "Step 7: unmounting top-level subvolume..."
umount /mnt/toprollback

echo ""
echo "Done. Reboot now to switch to snapshot ${TARGET_NUMBER}."
echo "@oldtrash will be cleaned up automatically after a successful boot."
