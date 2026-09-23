# third-party: system packages the admin installs

A few packages only work when installed system-wide by root, because they
are setuid or talk to the kernel as root. Building apt/dpkg without root in
a rootless podman container needs them, so the admin installs them once:

```sh
sudo bash third-party/install-tools.sh [--with-podman]
```

| package | why root |
|---|---|
| `uidmap` | setuid `newuidmap`/`newgidmap`, for subuid ranges in user namespaces |
| `fuse3` | setuid `fusermount3` |
| `podman` (optional) | rootless containers need the setuid helpers above |

Everything else (bwrap, slirp4netns, fuse-overlayfs, …) is
ordinary software that the user installs with the userspace apt. Run
`admin/enable-userspace.sh` first: it turns on what the kernel and system
must allow (user namespaces, subuid/subgid).
