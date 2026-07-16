#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

# --- argument pre-processing -------------------------------------------------
# Pull --silent out of the args wherever it appears, leave the rest untouched.
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

# --- logging -------------------------------------------------------------------
# Skipped in --auto-finish mode (unattended boot; output goes to the journal
# via systemd anyway) and when --silent was given.
if [ "$1" != "--auto-finish" ] && [ "$SILENT" -ne 1 ]; then
  TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
  LOG_FILE="/var/log/rollback_${TIMESTAMP}.log"
  exec > >(tee -i "$LOG_FILE") 2>&1
  echo "=== Rollback Script Started ==="
  echo "$LOG_FILE $(date '+%Y-%m-%d %H:%M:%S')"
  echo "================================"
fi

# --- self-install --------------------------------------------------------------
INSTALL_PATH="/usr/local/bin/rollback"
SCRIPT_REAL=$(realpath "$0")
if [ "$SCRIPT_REAL" != "$INSTALL_PATH" ]; then
  cp "$SCRIPT_REAL" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
fi

AUTOFINISH_SERVICE="/etc/systemd/system/rollback-finish.service"

ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
ACTIVE_NAME=$(btrfs subvolume show / | awk 'NR==1{print $1}')

do_finish() {
  echo "Step 1: mounting top-level subvolume..."
  mkdir -p /mnt/toprollback
  mount -o subvolid=5 "$ROOT_DEV" /mnt/toprollback

  echo "Step 2: renaming old, now inactive @ to @oldtrash..."
  [ -d "/mnt/toprollback/@" ] &&
    mv "/mnt/toprollback/@" "/mnt/toprollback/@oldtrash"

  echo "Step 3: deleting @oldtrash..."
  [ -d "/mnt/toprollback/@oldtrash" ] &&
    if ! btrfs subvolume delete "/mnt/toprollback/@oldtrash"; then
      echo "Warning: failed to delete @oldtrash immediately (likely disk full). You can delete it later with rollback --finish."
    fi

  echo "Step 4: renaming @new to @ ..."
  mv "/mnt/toprollback/@new" "/mnt/toprollback/@"

  echo "Step 5: setting @ as the default subvolume..."
  NEW_ID=$(btrfs subvolume list /mnt/toprollback | grep "path @$" | awk '{print $2}')
  btrfs subvolume set-default "$NEW_ID" /mnt/toprollback
  echo "Default subvolume set to @ (ID ${NEW_ID})."

  echo "Step 6: unmounting top-level subvolume..."
  umount /mnt/toprollback

  echo "Step 7: regenerating grub config..."
  if command -v update-grub >/dev/null; then
    update-grub
  fi
}

cleanup_autofinish_service() {
  systemctl disable rollback-finish.service >/dev/null 2>&1 || true
  rm -f "$AUTOFINISH_SERVICE"
  systemctl daemon-reload
}

if [ "$1" = "--auto-finish" ]; then
  if [ "$ACTIVE_NAME" != "@new" ]; then
    cleanup_autofinish_service
    exit 0
  fi

  do_finish
  cleanup_autofinish_service

  echo "Auto-finish complete. Rollback is fully applied and @ is clean again."
  exit 0
fi

if [ "$1" = "--finish" ]; then
  if [ "$ACTIVE_NAME" != "@new" ]; then
    echo "Error: active root is '${ACTIVE_NAME}', not '@new'."
    echo "Nothing to finish. Did you already finish, or did the reboot not happen?"
    exit 1
  fi

  do_finish
  cleanup_autofinish_service

  echo ""
  echo "Finished. Rollback is fully applied and @ is clean again."
  echo "Verify with:"
  echo "  cat /proc/cmdline"
  echo "  sudo btrfs subvolume get-default /"
  exit 0
fi

TARGET_NUMBER="$1"

if [ "$ACTIVE_NAME" = "@new" ]; then
  echo "Error: active root is already '@new' — a rollback is in progress."
  echo "Reboot first; cleanup should run automatically. If it doesn't, run: rollback --finish"
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

echo "Step 3: removing any stale @new from a previous incomplete run..."
if [ -d "/mnt/toprollback/@new" ]; then
  btrfs subvolume delete "/mnt/toprollback/@new"
fi

echo "Step 4: creating @new from the content of snapshot ${TARGET_NUMBER}..."
btrfs subvolume snapshot "/mnt/toprollback/.snapshots/${TARGET_NUMBER}/snapshot" "/mnt/toprollback/@new"

echo "Step 5: setting @new as the default subvolume..."
NEW_ID=$(btrfs subvolume list /mnt/toprollback | grep "path @new$" | awk '{print $2}')
btrfs subvolume set-default "$NEW_ID" /mnt/toprollback
echo "Default subvolume set to @new (ID ${NEW_ID})."

echo "Step 6: installing auto-finish helper directly inside @new..."
# This must be written into @new's own filesystem tree, not the currently
# active @. @new's content is frozen at the moment the target snapshot was
# taken, so anything we write to the live @ here would never appear once
# we boot into @new. The systemd unit is enabled by hand-creating the
# same symlink "systemctl enable" would make, since @new isn't running yet.
mkdir -p "/mnt/toprollback/@new/usr/local/bin"
cp "$SCRIPT_REAL" "/mnt/toprollback/@new${INSTALL_PATH}"
chmod +x "/mnt/toprollback/@new${INSTALL_PATH}"

mkdir -p "/mnt/toprollback/@new/etc/systemd/system/multi-user.target.wants"
cat <<EOF >"/mnt/toprollback/@new/etc/systemd/system/rollback-finish.service"
[Unit]
Description=Finish pending btrfs rollback (one-shot, self-disabling)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --auto-finish

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "/mnt/toprollback/@new/etc/systemd/system/rollback-finish.service"
ln -sf "../rollback-finish.service" \
  "/mnt/toprollback/@new/etc/systemd/system/multi-user.target.wants/rollback-finish.service"

echo "Step 7: unmounting top-level subvolume..."
umount /mnt/toprollback

echo "Step 8: regenerating grub config..."
if command -v update-grub >/dev/null; then
  update-grub
fi

echo ""
echo "Step 1 of 2 complete. The old @ is still in place but is now inactive."
echo "Reboot now to switch to snapshot ${TARGET_NUMBER} (running as @new)."
echo "Cleanup will run automatically on next boot."
echo "If you want to verify it run: systemctl status rollback-finish.service (should be inactive/disabled after success)"
