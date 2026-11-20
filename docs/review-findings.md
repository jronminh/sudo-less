# Security review findings

These findings record the September 2026 reviews. See the [security model](security.md) for current guarantees and limits.

## Package extraction and the install view

Closed in old tracker #29. The review examined whether archive extraction and
maintainer scripts could reach the user's home. The earlier install view allowed
maintainer scripts to read and write there. Extraction also reached the home
through directory symlinks and archive path traversal. Unprivileged extraction
dropped the setuid bit in both the old and hardened views.

The standalone `deb2home` extractor was removed. Dpkg and maintainer scripts
now run in a private mount namespace with writable prefix system directories and
read-only access to sudo-less tooling. The sandbox hides the rest of the home,
provides a private temporary directory and an empty runtime directory, and
blocks access to removable-media and mount directories. A local package archive
from outside the prefix is exposed read-only.

The checks confirmed that the hardened view hid unrelated home files and
blocked the tested script reads and writes, symlink traversal across packages,
and archive path traversal. The review also found that packaged units could
weaken service isolation. The unit translator now enforces a minimum sandbox
and keeps package settings from disabling it. Running an installed program
directly still grants it the user's access. The sandbox has limits around
network access and abstract Unix sockets.

## Service sandbox directive handling

Closed in old tracker #38 (medium severity). The unit translator inserted
package-controlled sandbox directive values into the generated service command
line. Systemd's parsing could let those values change the sandbox wrapper's
arguments. The service could start with broader access to the user's files and
the host filesystem while inspection output still showed the expected defaults.
Systemd still enforced `NoNewPrivileges=yes` separately.

The translator now writes sandbox directives as data in the generated unit.
The sandbox reader applies them without passing their values through systemd's
command-line parser. The translator also discards package-authored sandbox
markers and excludes comments when checking which defaults it must add.

Retesting confirmed that both malformed directive values tested prevented service startup, forged
markers could not suppress home isolation, and representative services still
started with home isolation and syscall filtering enabled.
