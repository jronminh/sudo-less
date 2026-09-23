# Perl

**Debian section:** `perl`. **Status:** installs; tier `env`.

Perl's `@INC` does not include `$PREFIX`, so modules installed there are
not found. Set `PERL5LIB` to the prefix's two module trees:

```sh
PERL5LIB=$PREFIX/usr/share/perl5:$PREFIX/usr/lib/x86_64-linux-gnu/perl5/5.42
```

The second path carries the architecture triplet and Perl's version, so it
is host-specific. Example: `recipes/pmarkdown.recipe`. History: issue #7.

**To do:** an `install.sh` hook that writes `PERL5LIB` into the shell `PATH`
block with the host's own triplet and version, so no recipe pins it.
