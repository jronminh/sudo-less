#!/usr/bin/env bash
# privilege-surface.sh — what a fresh Debian install gives an unprivileged
# user: setuid/setgid files, polkit, root D-Bus services, udev rules and
# sysctls, and which packages bring them. docs/admin-features.md
# ("Debian's privilege surface, measured" and "What packages ask for") is
# its result.
#
#   OUT=~/surface dev/privilege-surface.sh [SUITE [ARCH]]
#
# The fresh install is what debian-installer puts on a system with no task
# chosen: every package of priority required, important or standard
# (https://wiki.debian.org/tasksel), plus their Depends, Pre-Depends and
# Recommends (the installer installs Recommends). Dependencies are resolved
# crudely, first alternative only, from the archive's Packages index; the
# Contents index gives polkit, D-Bus and udev files without downloading.
# Setuid bits are read from the .deb files themselves (about 130 MB, kept in
# OUT/debs), from their tmpfiles.d `z` lines, applied by systemd-tmpfiles in
# postinst (ssh-agent), and from this host's dpkg-statoverride, where other
# postinst scripts set them (dbus-daemon-launch-helper).
#
# Last, the whole archive: how many packages ship each kind of file that
# needs a privilege (from the Contents index alone, so what a package
# carries, not what it needs to run; maintainer scripts are not covered).
#
# Needs only curl, xz, gzip, python3 and dpkg-deb; no root.
set -euo pipefail

SUITE="${1:-forky}"
ARCH="${2:-$(/usr/bin/dpkg --print-architecture)}"
OUT="${OUT:-$PWD/surface}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
mkdir -p "$OUT/debs"
cd "$OUT"

[ -s Packages ] || curl -sf "$MIRROR/dists/$SUITE/main/binary-$ARCH/Packages.xz" | xz -d > Packages
# Architecture: all packages are listed in Contents-all, not Contents-$ARCH.
[ -s Contents ] || for c in "$ARCH" all; do
  curl -sf "$MIRROR/dists/$SUITE/main/Contents-$c.gz" | gzip -d
done > Contents

# fresh.txt: the fresh install set; urls.txt: its .deb files.
python3 - <<'EOF'
import re
P, prov, cur = {}, {}, {}
for l in open('Packages'):
    l = l.rstrip('\n')
    if not l:
        if cur: P.setdefault(cur['Package'], cur)
        cur = {}
        continue
    if l[0] != ' ':
        k, _, v = l.partition(': ')
        cur[k] = v
for n, c in P.items():
    for x in c.get('Provides', '').split(','):
        x = x.strip().split(' ')[0]
        if x: prov.setdefault(x, n)
def deps(c):
    for g in ','.join(c.get(f, '') for f in ('Pre-Depends', 'Depends', 'Recommends')).split(','):
        for alt in g.split('|'):
            n = re.sub(r'[ (:].*', '', alt.strip())
            n = n if n in P else prov.get(n)
            if n:
                yield n
                break
todo = [n for n, c in P.items() if c.get('Priority') in ('required', 'important', 'standard')]
seen = set()
while todo:
    n = todo.pop()
    if n not in seen and n in P:
        seen.add(n)
        todo.extend(deps(P[n]))
open('fresh.txt', 'w').write(''.join(f'{n}\t{P[n]["Priority"]}\n' for n in sorted(seen)))
open('urls.txt', 'w').write(''.join(P[n]['Filename'] + '\n' for n in sorted(seen)))
EOF
echo "fresh install: $(wc -l < fresh.txt) packages"

echo "== setuid/setgid in the .deb files"
(cd debs && sed "s|^|$MIRROR/|" ../urls.txt | xargs -P8 -n1 curl -sfO -C - || true)
for d in debs/*.deb; do
  /usr/bin/dpkg-deb -c "$d" | awk -v p="$(basename "${d%%_*}")" \
    '$1 ~ /^-..[sS]|^-.....[sS]/ {print "  " $1, p, substr($NF, 2)}'
done
echo "== set by systemd-tmpfiles at configure time (z lines in tmpfiles.d)"
for d in debs/*.deb; do
  /usr/bin/dpkg-deb --fsys-tarfile "$d" | tar -xO --wildcards './usr/lib/tmpfiles.d/*' 2>/dev/null \
    | awk -v p="$(basename "${d%%_*}")" '$1 ~ /^[zZ]/ && $3 ~ /^[0-7]?[2467][0-7][0-7][0-7]$/ {print "  " $3, p, $2}' || true
done
echo "== set by maintainer scripts (this host's dpkg-statoverride)"
/usr/bin/dpkg-statoverride --admindir /var/lib/dpkg --list | sed 's/^/  /'

echo "== files by kind, from the fresh set"
python3 - <<'EOF'
import re, collections
S = {l.split('\t')[0] for l in open('fresh.txt')}
kinds = {'polkit action': r'usr/share/polkit-1/actions/',
         'polkit rule': r'usr/share/polkit-1/rules.d/',
         'root D-Bus service': r'usr/share/dbus-1/system-services/',
         'udev rule': r'usr/lib/udev/rules.d/',
         'sysctl': r'usr/lib/sysctl.d/'}
hits = collections.defaultdict(lambda: collections.defaultdict(list))
for line in open('Contents'):
    path, _, pk = line.rstrip().rpartition(' ')
    path = path.strip()
    for k, p in kinds.items():
        if path.startswith(p):
            for x in pk.split(','):
                n = x.split('/')[-1]
                if n in S: hits[k][n].append(path[len(p):])
for k in kinds:
    print(f'  {k}:')
    for n, f in sorted(hits[k].items()):
        print(f'    {n}: {len(f)} ({", ".join(sorted(f)[:4])}{", ..." if len(f) > 4 else ""})')
for n in ('polkitd', 'uidmap', 'fuse3', 'bubblewrap', 'sudo'):
    print(f'  {n}: {"in" if n in S else "NOT in"} the fresh install')
EOF

echo "== this host against the fresh set"
/usr/bin/dpkg-query --admindir=/var/lib/dpkg -W -f='${db:Status-Abbrev} ${Package}\n' \
  | awk '$1 == "ii" {print $2}' | sort > installed.txt
cut -f1 fresh.txt | comm -23 - installed.txt > missing-here.txt
echo "  $(wc -l < missing-here.txt) fresh-install packages are not installed here (missing-here.txt)"

echo "== the whole archive: packages per kind of file"
python3 - <<'EOF'
import collections
total = sum(1 for l in open('Packages') if l.startswith('Package: '))
kinds = [('system service (unit or init script)', ('usr/lib/systemd/system/', 'etc/init.d/')),
         ('system user (sysusers.d)', ('usr/lib/sysusers.d/',)),
         ('tmpfiles.d', ('usr/lib/tmpfiles.d/',)),
         ('udev rule', ('usr/lib/udev/rules.d/',)),
         ('user service (user unit)', ('usr/lib/systemd/user/',)),
         ('D-Bus system policy', ('usr/share/dbus-1/system.d/',)),
         ('polkit action', ('usr/share/polkit-1/actions/',)),
         ('PAM', ('etc/pam.d/', 'usr/lib/pam.d/')),
         ('cron.d', ('etc/cron.d/',)),
         ('dkms module source', ('usr/src/',)),
         ('kernel module', ('usr/lib/modules/',)),
         ('modprobe.d', ('usr/lib/modprobe.d/',)),
         ('sysctl.d', ('usr/lib/sysctl.d/',)),
         ('any of the above but user units and tmpfiles.d', None),
         ('for scale: a program in /usr/bin', ('usr/bin/',)),
         ('for scale: a desktop entry', ('usr/share/applications/',))]
anyof = tuple(q for k, ps in kinds if ps and k not in ('tmpfiles.d', 'user service (user unit)')
              and not k.startswith('for scale') for q in ps)
h = collections.defaultdict(set)
for line in open('Contents'):
    path, _, pk = line.rstrip().rpartition(' ')
    path = path.strip()
    names = {x.split('/')[-1] for x in pk.split(',')}
    for k, ps in kinds:
        if path.startswith(ps or anyof) and (k != 'dkms module source' or path.endswith('/dkms.conf')):
            h[k] |= names
print(f'  {total} packages')
for k, _ in kinds:
    print(f'  {len(h[k]):6d} {100 * len(h[k]) / total:5.1f}%  {k}')
EOF
