# dsb: a bounded middle identity, for development

[**dsb**](https://github.com/jronminh/dsb) (debian superuser bridge) is
`sudo` for a bounded identity instead of root: the admin writes once, in
`/etc/dsb/dsb.conf`, what each identity may do, and the kernel enforces it.
It started here as `tools/updo` and is now a separate project; its design,
security model and tests live there.

For sudo-less it is an optional admin step, in the same "enable once, never
run the user's software as root" shape as `admin/native/enable-userspace.sh`
(`docs/roles.md`). Nothing in sudo-less needs it to work.

## The policy: `admin/dsb/sudo-less.conf`

Install the `dsb` package, then, as the admin:

```sh
install -m 644 admin/dsb/sudo-less.conf /etc/dsb/conf.d/sudo-less.conf
dsb-admin apply
```

| identity | grant | used for |
|---|---|---|
| `dsb` (default) | none: a shell, any command, its own home | the everyday middle identity from dsb's shipped config |
| `sl-fresh` | none: a shell, any command, its own home `/var/lib/dsb/sl-fresh` | testing the supported install path as a new user meets it: no `~/.local`, no `PATH` or dotfiles of `master` |
| `sl-journal` | group `systemd-journal`, only `journalctl` | reading the system journal while developing: effects of `admin/*.sh`, system units, Waydroid, dsb's own audit trail |

```sh
dsb -u sl-fresh -p bootstrap.sh bash          # a clean install, from scratch
dsb -u sl-fresh -c 'apt-get install -y jq && jq --version'
dsb -u sl-fresh -c 'rm -rf ~/.local ~/.cache ~/.profile'   # reset
dsb -u sl-journal journalctl -b -u waydroid-container
```

None of these can write anything root reads, run setuid programs or gain a
capability; `sl-fresh` and `dsb` are strictly less than a normal user.

### Tested

Applied on the reference machine (Debian sid, dsb 0.1.0). `sl-journal` reads
the journal, including dsb's audit entries, and is refused anything else.
The first `sl-fresh` bootstrap found three bugs in the supported install
path for an account created without `/etc/skel`, all fixed in
`scripts/setup/install-shell-path.sh`:

- with neither `~/.bashrc` nor `~/.profile`, nothing put the prefix on
  `PATH`, silently; it now creates `~/.profile`;
- the `PATH` block only fired when `$PREFIX/usr/bin` existed, not
  `$PREFIX/bin` (where the prebuilt apt/dpkg live);
- plain `dpkg` used the prebuilt's compiled-in admindir (the build machine's
  `/root/.local`); `DPKG_ADMINDIR` now points it at the prefix.

`bootstrap.sh` runs the scripts from the release tarball, so the fix reaches
it with the next release. On a host without `gpgv`, `apt-get update` still
fails with "not signed", as bootstrap already warns.

## Tier `limited`: no candidates

The plan was a tier `limited`: a package whose only obstacle is one
privileged step runs that step through a narrow dsb identity. Checked
against the two `never` recipes it was meant for, it does not hold:

| recipe | the privileged step | why not dsb | the actual way |
|---|---|---|---|
| `javascript-common` | postinst `mkdir -p /etc/lighttpd/conf-enabled` | lighttpd starts as root and its config can run commands as root (`include_shell`): **a write grant on `/etc/lighttpd` is root**. Even `commands = mkdir` alone allows `mkdir -m 777`, after which anyone can drop config there. | a path shim redirecting `/etc/lighttpd` into `$PREFIX` (tier `direct`), or the admin creating the empty, root-owned directory once |
| `screen` | `/run/screen` in group `utmp`, `/etc/tmpfiles.d`, a unit link, `update-rc.d` | most of it is root-executed config, refused by design; `dpkg --configure` still fails | stays `never`; the system's `screen` (or `SCREENDIR` with a userspace build) |

The rule behind it, now also in dsb (`dsb-admin` warns on any `write =`
under `/etc`): a daemon's config directory is root, because the daemon
starts as root and reads it. Grant data, never config. Packages that need
more than their own data are services, which `docs/standard.md` already
puts out of scope.
