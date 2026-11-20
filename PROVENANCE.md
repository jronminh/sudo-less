# Provenance

This tree was assembled on 2026-11-20 from two public repositories, with
fresh history.

## sudo-less

- Branch `main`, commit `3a306bbc068a0b43e56d30e218bcf2e4d7006de5` (the only branch).
- Uncommitted changes included: no (working tree was clean).
- Taken: the whole tracked tree, at the repo root, layout unchanged.
- Changed: `.gitignore` (`src/` and `dist/` anchored to the root so they no
  longer ignore `dsb/src/`; the private-notes pattern `todo.md` renamed to
  `todo.local.md`, since it would hide `TODO.md` on case-insensitive file
  systems); `README.md` (a section on dsb, `dsb/` in the layout, the dsb
  link points at the folder); `docs/methodology.md`, `dev/dsb/README.md`,
  `apt-dpkg/patches/UPSTREAM.md` (two links to `docs/` that were already
  broken in the source, one level too shallow),
  `dev/dsb/sudo-less.conf` (links to the dsb repo point at `dsb/`).
- Left out: `docs/demo.gif` (see `EXCLUDED.md`).
- Open GitHub issues folded into `TODO.md`.

## dsb

- Branch `main`, commit `7726bb5a488d7d3c331841e70ed5b2333275e7e9` (the only branch).
- Uncommitted changes included: no (working tree was clean).
- Taken: the whole tracked tree, into `dsb/`, layout unchanged, including
  its `LICENSE` (identical to the root one, GPL-3.0) and `.gitignore`.
- Changed: `dsb/README.md` ("Used by" links to this repo's README and
  `dev/dsb/`, prefix `~/.sudo-less`), `dsb/docs/design.md` (sudo-less link
  made relative), `dsb/docs/rootcall.md` (issue link points at `TODO.md`).
- Left out: nothing.
- The [rootcall proposal](TODO.md#rootcall) was carried over from the old tracker.
