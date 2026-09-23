# dsb: the middle identity for tier `limited`

Some packages are blocked by one privileged step only (a `mkdir` under
`/etc`, a directory in a system group). Root is too much for that, and
userspace cannot do it. The middle identity is
[**dsb**](https://github.com/jronminh/dsb) (debian superuser bridge), a
separate project that started here as `tools/updo`: `sudo` for a bounded
identity instead of root, configured by the admin once in
`/etc/dsb/dsb.conf` and enforced by the kernel. Its design, security model
and tests are in that repository.

For sudo-less, installing the `dsb` package is an optional admin step, in the
same "enable once, never run the user's software as root" shape as
`admin/native/enable-userspace.sh` (`docs/roles.md`). The two are unrelated:
either works without the other.

## Tier `limited`

A package whose only obstacle is a privileged step becomes `limited`. The
recipe names the dsb identity it needs, and the step runs through `dsb`, not
root:

| today `never` | with dsb |
|---|---|
| `javascript-common`: postinst `mkdir -p /etc/lighttpd/conf-enabled` | **limited**: `[identity lighttpd] write = /etc/lighttpd`; the recipe runs `dsb -u lighttpd mkdir -p /etc/lighttpd/conf-enabled`, then `dpkg --configure` |
| `screen`: `/run/screen`, group `utmp`, mode `0775` | **limited**: `groups = utmp` + `write = /run/screen` |
| `screen`: `/etc/tmpfiles.d`, unit link, `update-rc.d` | **never**: root-executed config, which dsb refuses to grant; the admin may ship a reviewed static file once instead |
| services on ports < 1024 | no dsb needed: `net.ipv4.ip_unprivileged_port_start` is an admin-once sysctl |
| PAM, setuid | **never**: blocked by `NoNewPrivileges` and dsb's forbidden paths, by design |
| 32-bit-only, proprietary self-updating | unchanged: not about privilege |

`recipes.sh` would check that `dsb -u NAME -l` answers (the identity exists
and the caller may use it) before running a `limited` recipe, and name the
missing `dsb.conf` section when it does not. Not implemented yet.
