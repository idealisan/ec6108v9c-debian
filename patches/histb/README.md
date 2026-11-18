# histb patch store (quilt)

Out-of-tree patch series for the HiSilicon STB platforms (Hi3798MV100 /
Hi3716CV200 / Hi3798MV200 / Hi3798MV200H). The patch files here are the
source of truth, a git branch is not. The `series` file is tracked in git and
lists every patch by its store-root file name; there are no bucket
directories. Kernel trees are disposable and are extracted from the baseline
commit named in `baseline`.

This file states only what is specific to this store - layout, class order,
numbering and the grouping decisions. quilt itself is documented by quilt.
checkpatch is a pre-submission spot-check tool, not a store gate. Cutting a
submission out of the series, writing its introduction and sending it are a
separate upstreaming process.

## Layout

```
series              the order patches apply in (flat file names, tracked)
baseline            kernel version + commit every patch applies to
quilt.conf          --fuzz=0, -p ab refresh, and QUILT_PATCHES pointing here
*.patch             every patch, flat in this root
```

`quilt.conf` defaults `QUILT_PATCHES` to the directory it lives in, so a tree
only has to name the file:

```sh
quilt --quiltrc=<this directory>/quilt.conf push -a
```

`new` and `refresh` then write into this directory, `series` included - there is
no staging copy and nothing to sync back. `.pc/` stays in the tree, so an arm
and an arm64 tree can work against one store. Patches apply with `--fuzz=0`.

Get a tree by extracting `BASE_SHA` from `baseline`
(`git -C <kernel repository> archive <BASE_SHA> | tar -x -C <tree>`, about
1.9 GB) and take the kernel version and configuration from `baseline` too.

Renumbering or splitting patches is a file rename plus a `series` edit;
`quilt new` and `quilt delete` edit `series` in place.

Do not run `quilt init` in this directory: init would add a `.pc/` here, and
`.pc/` belongs in the tree.

## Numbering

`NNN[-SS]-<shortname>.patch`; the shortname is exactly what `git format-patch`
derives from the patch's `Subject:` line (original case kept, `_` and `.`
kept, truncated at 52 characters) - rename a patch by rewriting its subject,
never by hand-editing the file name.

| range | content | numbering |
|---|---|---|
| 0xx | patches taken from another kernel version (upstream backports, none yet) | one number each, no series grouping; named `0NN-vX.Y-<shortname>` for the kernel version they came from |
| 1xx-8xx | submittable patches | `NNN-SS`: **NNN is one submission** - the series that goes to one maintainer - and SS is the position of a patch inside it. A submission uses `NNN-SS` throughout, never bare `NNN` alongside `NNN-SS` |
| 9xx | local-only content (bring-up instrumentation, bench harness), never submitted | one number each, no series grouping |

Class order is dependency order (a provider always precedes its consumers):

| range | class |
|---|---|
| 1xx | shared ABI prerequisites: dt-bindings consumed by 2+ submissions, vendor prefixes, txt-to-YAML conversions |
| 2xx | fixes to existing drivers and cores, arch/machine/Kbuild changes |
| 3xx-7xx | new driver introductions (a driver's own binding stays in the same `NNN`) |
| 8xx | board integration: dtsi/board dts, multi_v7 configs |
| 9xx | hack (local-only) |

The hundreds digit of 3xx-7xx is a **size band**, banding by added lines across
the submission - the same ladder the store has always used, shifted one band
down when 0xx was reserved for backports (guidance for picking an `NNN`, not a
hard rule; nothing validates the limits):

| band | limit |
|---|---|
| 3xx | 250 |
| 4xx | 800 |
| 5xx | 2,000 |
| 6xx | 5,000 |
| 7xx | 20,000 |

(the original 10,000 rung is unused after the flattening; the ladder stays
250 / 800 / 2,000 / 5,000 / 20,000)

**Inserting a new group**: pick any free number between the neighbours - a
non-multiple of 5 in the middle is fine (e.g. `307` between `305` and `310`)
- and leave every other number untouched. Renumbering back onto clean
5-multiple spacing happens only when explicitly asked; it is not part of an
insertion.

Within 1xx-8xx a patch file belongs to the submission its change semantically
belongs to; the series order is decided by the numbering alone. The class
order already puts providers ahead of their consumers, so a later patch may
carry context an earlier submission produced (e.g. `MAINTAINERS` sections
sharing one insertion point).

## Grouping rules

1. Fix or new driver: does the patch create the driver source file (a `--- /dev/null`
   hunk for a `.c`/`.h`)? If yes, it is an introduction.
2. Changes to a driver this series itself introduces are folded into the tail of
   that submission's `SS` range - they are not independently submittable.
3. A dt-bindings or shared id header consumed by 2 or more submissions belongs in
   the earliest such submission. Inside a single submission it cannot be
   cherry-picked alone, and it would not survive a per-patch build test.
4. The series order is decided by the numbering alone; a later patch may depend
   on context an earlier submission produced.

## Submission headers

- Each patch header is what `git format-patch` emits, kept verbatim (the
  OpenWrt patches convention): a `From <sha> Mon Sep 17 00:00:00 2001` first
  line, then `From:`, `Date:` and a `Subject:` carrying the format-patch
  token — bare `[PATCH]` for a one-number patch (0xx backports, 9xx hack) or
  a single-patch submission, `[PATCH n/m]` inside a multi-patch submission
  (one NNN group = one submission, numbered by the filename's SS order) —
  then the message body, then the bare `---` separator followed by the
  format-patch diffstat (kept, like OpenWrt keeps it). The commit message
  itself stays bare: the token comes from
  `git format-patch --subject-prefix="PATCH n/m"` at header-install time.
  Filename derivation strips the token, so names are unaffected. A
  `quilt new` patch has none of this until a header is installed from a
  `git format-patch` run of the same commit; `quilt mail` would stack its
  own numbering on top, so sending must not renumber.
- Per-patch authorship and date ride directly on `From:` / `Date:`; the
  nominal author always carries a `Signed-off-by:`.
- Patch bodies are quilt-format unified diffs, exactly what `quilt refresh`
  produces with this `quilt.conf`: `--- a/` / `+++ b/`, `--- /dev/null` for new
  files, and no `diff --git` / `index` / diffstat lines or git signature.

Splitting a submission out of `series` and writing what goes on top of it is not
this repository's business; upstreaming decides the rest.
