# Services

A package's services are systemd units written for the system manager
(PID 1, root). sudo-less runs them under the user's own manager,
`systemd --user`, after translating them: `tools/prefix-units.sh`, run by
the apt hook `apt-dpkg/config/apt.conf.d/04units.in` after every dpkg run.
This page is what the user manager can do, how a unit is translated, and
what is left.

## The user manager

Every logged-in user has a systemd instance of their own,
`user@UID.service`, running as that user. It starts at the first login and
stops at the last logout, unless the admin enables **linger** for the user
(`loginctl enable-linger`), which starts it at boot and keeps it
([`admin-features.md`](admin-features.md)). It reads units from, among
others, `~/.config/systemd/user`, `~/.local/share/systemd/user`
(`$XDG_DATA_HOME`), `/etc/systemd/user` and `/usr/lib/systemd/user`
(systemd.unit(5), "User Unit Search Path"); `prefix-units` writes to the
second. It has its own journal (`journalctl --user`), its own targets
(`default.target`, `basic.target`, `sockets.target`, `timers.target`, the
graphical-session ones) and none of the system's (`multi-user.target`,
`network.target`).

Measured on this host (systemd 261, 2026-09-25, `systemd-run --user`):

| a unit asks for | under the user manager |
|---|---|
| `Type=notify`, `simple`, `forking`, `oneshot`; `Restart=`; timers; sockets on a port from 1024 or a path in `$XDG_RUNTIME_DIR`; path units | works |
| `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=`, `ConfigurationDirectory=` | works, under the user's XDG directories: `$XDG_RUNTIME_DIR/X`, `~/.local/state/X`, `~/.cache/X`, `~/.local/state/log/X`, `~/.config/X`; `%t`, `%S`, `%C`, `%L`, `%E` expand to the same |
| `MemoryMax=`, `CPUQuota=`, `TasksMax=` | works: the user's slice is delegated the `cpu`, `memory` and `pids` controllers |
| `IOWeight=`, `AllowedCPUs=` | ignored: `io` and `cpuset` are not delegated (the **cgroups** grant in [`admin-features.md`](admin-features.md)) |
| `ProtectSystem=`, `ProtectHome=`, `PrivateTmp=`, `PrivateNetwork=`, `NoNewPrivileges=`, `SystemCallFilter=` | works: the manager builds the sandbox in a user namespace of its own (uid map `1001 1001 1`) |
| `User=`, `Group=`, `DynamicUser=` | the service fails to start (`status=216/GROUP`) |
| `AmbientCapabilities=`, `CapabilityBoundingSet=` with a capability the user lacks | the service fails to start (`status=218/CAPABILITIES`) |
| `WantedBy=multi-user.target`, `After=network.target` | the target does not exist: `WantedBy=` enables nothing, `After=` is ignored |
| a port below 1024, a TUN device, a firewall rule, a large socket buffer | refused by the kernel, as for any process of the user |

So the manager can run almost any service; what it cannot do is change
identity or gain a privilege, the same limits as everything else in
sudo-less.

## Translation

`prefix-units` turns each unit of a changed package, system or user, into
a user unit in `~/.local/share/systemd/user`, tagged
`# sudo-less user unit (prefix-units); regenerated, do not edit`:

| part of the unit | becomes |
|---|---|
| `User=`, `Group=`, `DynamicUser=`, `SupplementaryGroups=`, capabilities, `PAMName=`, `SocketUser=` | dropped: the service runs as the user |
| an `Exec` line whose program has a `prefix-wrap` script, names a file in the prefix, or names state in `/var/lib`, `/var/log`, `/var/cache`, `/var/spool` | `prefix-view --service CMD`: a fresh [service view](view.md#the-service-view), with the prefix on `/usr`, `/etc`, `/opt` and `/var`, so the daemon reads its config and keeps its state and logs where Debian puts them, and it all lands in the prefix |
| any other `Exec` line | runs directly, the program's path in the prefix if it is there |
| sandboxing that names paths or builds a mount namespace (`ProtectSystem=`, `ProtectHome=`, `Private*=`, `ReadWritePaths=`, `BindPaths=`, ...), for a program from the prefix | dropped: the paths are the host's, and `ProtectHome=` would hide the prefix itself |
| `RestrictNamespaces=`, `SystemCallFilter=`, for a unit run in the view | dropped: the view needs `unshare` and `setns` |
| `/run/X`, `/var/run/X` anywhere | `%t/X` (`$XDG_RUNTIME_DIR/X`) |
| `EnvironmentFile=`, `PIDFile=`, `WorkingDirectory=`, `Condition*=`, `Listen*=`, `Path*=` | the prefix's copy of the path, when there is one: systemd reads these itself, outside the view |
| dependencies on system targets, `.mount`, `.device`, `.slice` units | dropped |
| `WantedBy=`, `RequiredBy=` a system target | `WantedBy=default.target` |

A package that ships a user unit of the same name (syncthing, mpd) gets
its user unit, unchanged but for the paths. Drop-in directories
(`*.service.d`) are not read.

## Lifecycle

- **install:** a unit the package enabled (its postinst's
  `deb-systemd-helper enable`, run in the install view, leaves symlinks in
  `$PREFIX/etc/systemd`) is enabled and started, `systemctl --user enable
  --now`, as Debian starts a service on install. apt runs dpkg twice
  (unpack, configure) and the symlinks appear in the second run, so
  `prefix-units` keeps a marker per unit it enabled
  (`$PREFIX/var/lib/sudo-less/units-enabled`) and checks every package's
  units on each run.
- **upgrade:** a unit whose translation changed is rewritten and
  restarted if it is running.
- **remove:** the package's units are stopped, disabled and deleted.
- `SUDO_LESS_UNITS=nostart` enables without starting; `SUDO_LESS_UNITS=off`
  skips it all. `prefix-units --check UNIT-FILE` prints a translation and
  changes nothing.

## Tried on this host (2026-09-25)

| package | unit | result |
|---|---|---|
| mini-httpd | system | ran in the service view, serving the prefix's `/var/www/html` and logging to its `/var/log/mini_httpd.log`, once its port was moved from 80 to 8080 |
| syncthing | its own user unit | ran as it is |
| tailscale | system, runs as root | ran, state in the prefix's `/var/lib/tailscale`, socket at `$XDG_RUNTIME_DIR/tailscale/tailscaled.sock` (the CLI needs `--socket=`), once `FLAGS="--tun=userspace-networking"` was set in `/etc/default/tailscaled`: a TUN device needs CAP_NET_ADMIN. The kernel also refuses its larger UDP buffers, which costs only throughput |
| webfs | system | not installed: its postinst runs `ucf`, which refuses a non-root user |

Removing mini-httpd and syncthing stopped them and deleted their units.

## How many packages this reaches

From the archive's Contents index (forky `main`, amd64 and `all`,
2026-09-25), counting `.service`, `.socket`, `.timer` and `.path` files:

| packages that ship | count |
|---|---|
| a system service (a unit or an init script) | 1471 |
| an init script and no unit | 25 |
| a unit and a `sysusers.d` file (a system user) | 196 |
| a unit and no `sysusers.d` file | 1250 |

The 1250 are the upper bound for this mechanism: a postinst that runs
`adduser --system` (redis, memcached) is not in the index, and
`prefix-check` refuses those packages before dpkg runs.

## What is left

| problem | cell in [`problems.md`](problems.md) | why |
|---|---|---|
| the service runs as a system user its package creates | install, never | the user exists only in the prefix's `/etc/passwd` |
| only an init script | run, never | nothing to translate; the init script expects root |
| a TUN device, firewall rules, raw sockets | run, never | CAP_NET_ADMIN or CAP_NET_RAW on the host; some daemons have a userspace mode (tailscale) |
| a port below 1024 | run, root once | `net.ipv4.ip_unprivileged_port_start` |
| large socket buffers | run, root once | `net.core.rmem_max`, `wmem_max`; throughput only |
| running before login and after logout | run, root once | linger |
| a postinst calling `ucf` | install, non-root, not done | `ucf` checks only the uid; the install view could satisfy it as it does `update-alternatives` |
| drop-ins; a failed unit is not restarted on upgrade | run, non-root, not done | `prefix-units` does not read `*.service.d` and restarts only running units |
| the unit's own sandbox is dropped | not a cell: it runs, less isolated | see below |

The sandbox is dropped for units run from the prefix, but the table above
shows the user manager builds it, and a probe (`ProtectSystem=strict`,
`PrivateTmp=yes` around `prefix-view --service`) ran the view inside it.
`ProtectSystem=` and `PrivateTmp=` could be kept, and likely
`PrivateDevices=` and `PrivateNetwork=` (untested with the view); the directives that name host paths
(`ReadWritePaths=`, `ProtectHome=`) would need their prefix paths instead.
Not done yet.
