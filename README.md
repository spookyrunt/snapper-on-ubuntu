## Snapper on Ubuntu
1. Run `./setup.sh` once for installation of `snapper` and configurations.
1. Run `./rollback.sh` instead of `sudo snapper rollback` that is extremely buggy.
1. Other `snapper` commands such as `sudo snapper list` still remain useful.

### rollback.sh
- `./rollback.sh #` replaces `sudo snapper rollback #` where # is your snapshot ID you may find on `sudo snapper list`.
- `./rollback.sh` installs itself in `/usr/local/bin/rollback` so that it can also be run as `rollback` thereafter.

### setup.sh
- Separates the root subvolume (`@`) from the snapshot tree, tunes `/etc/fstab` (`noatime`, `compress=zstd`, separate `/.snapshots` mount), and installs/configures `snapper` (timeline + apt hooks, automatic cleanup).
- `rollback.sh` depends on the resulting `@` + `/.snapshots` layout.
