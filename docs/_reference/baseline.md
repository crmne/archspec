---
title: Baseline
nav_order: 4
description: Pin the architecture as a snapshot with a receipt, then grade a change against it so a check reports what it introduced, resolved, or declared.
seo:
  title: ArchSpec snapshots and baseline checks
---

# Baseline

A rule set fails a tree. A baseline grades a change. `archspec snapshot` writes the analysed graph and a receipt under `.archspec/`; a later `archspec check --baseline` analyses the working tree, runs the same rules on both graphs, and reports the difference.

```sh
bundle exec archspec snapshot
# edit
bundle exec archspec check --baseline
```

The snapshot holds what the rules read: every parsed file with its parse errors and suppressions, every constant with its methods and mixins, every fact, and the component assignment. The receipt beside it records the ArchSpec version, the root, the source and ignore patterns, a digest of the parsed files, the rule ids that existed when it was taken and the fingerprints of the findings those rules raised, and the git commit with a dirty flag when the root is a repository. Both files are sorted YAML with no timestamp, so two snapshots of the same tree are identical. The graph is also written as `graph.bin`, the same document serialised with Marshal, which loads in a fraction of the time and is what a path-scoped check reads; the receipt carries its digest, and a payload that does not match, or was written by another ArchSpec or Prism version, is ignored for the YAML and the check says so. `.archspec/` ignores itself; nothing in it is meant to be committed.

## What a check reports

Diagnostics are matched by their todo id, so a finding that moved lines is the same finding. The todo file is subtracted on both sides first, so accepted debt never appears in the delta.

- **Introduced**: present now, absent in the snapshot. Printed with the full code frame.
- **Resolved**: present in the snapshot, absent now. Listed by file and message.
- **Declared**: introduced by a rule the snapshot did not know, in a file the change did not touch. The change declared the rule; it did not cause the breach. Printed with a note saying so.
- **Carried**: present in both. Counted, and printed only in strict mode.

Which files the change touched is read from the snapshot itself: it records a digest of every file it parsed, so a file whose content differs, or one the snapshot never saw, counts as touched. Nothing here asks git, so a tree that was dirty when the snapshot was taken compares against what was read, not against a commit. A snapshot without digests makes every new finding count as introduced, and the summary says the changed set was not read.

```text
introduced (1):

[error] models must not depend on controllers [dependencies.forbid]

app/models/post.rb:2:3
...

Architecture regressed (ratchet): 1 introduced, 1 resolved, 0 declared, 0 carried.
baseline: 3f2a9c1d4e5b
edges: +1 references_constant
changed files: read from the snapshot
current: 1 violation in all
facts: none (archspec_facts/ absent)
```

## Modes

```sh
bundle exec archspec check --baseline --mode ratchet
bundle exec archspec check --baseline --mode advisory
bundle exec archspec check --baseline --mode strict
```

`ratchet` is the default with a baseline and fails only on introduced findings. `advisory` prints the same report and always exits 0. `strict` fails on introduced and carried findings alike, which is a plain check with a richer report.

## When it declines

A comparison between two graphs that were not produced the same way is not a verdict. When the snapshot was taken by a different ArchSpec version, at a different root, or with different source or ignore patterns, `check --baseline` prints one line naming the cause and exits 3 without comparing anything. Take a new snapshot and check again. A changed `Archspec.rb` does not decline: declaring a rule is exactly what the delta exists to report.

## Exit statuses

| Status | Meaning |
|---|---|
| `0` | Clean, or nothing the mode fails on. |
| `1` | The mode failed the change. |
| `3` | The baseline is not comparable; nothing was graded. |
| `64` | Usage error. |

## JSON

`--format json` keeps `violations` as the full current list and adds `mode`, `baseline` (commit, dirty flag, version, rule ids), `introduced`, `resolved`, `declared`, a `carried` count, `edges` added and removed per type, and `changed_files_read`.

Path arguments scope every bucket the same way they scope a plain check. `--baseline` cannot be combined with `--update-todo`.
