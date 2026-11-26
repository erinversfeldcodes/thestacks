# Deletion manifests

The record of what was deleted from production object storage, by hand, outside
the application's own sweeps.

⛔ **A manifest here is an audit trail, not a tool.** Nothing reads these files.
They exist so that "what exactly was removed, when, and on whose decision" is
answerable from the repository rather than from memory — because the deletions
they record are irreversible and were made against production.

The *mechanism* for collecting row-less objects lives in the application:
`Stacks.GDPR.ImageRetention.cleanup_orphan_objects/1`, bounded, tested against
planted orphans, and invoked nightly by `ImageRetentionJob`. A future cleanup
should use that, not a one-off script.

⛔ **The manifests themselves do NOT live here, and that is the point of this
file.** This repository is **public**. A per-object manifest of a production
bucket — keys, sizes, timestamps — gives the public operational detail and gives
the audit nothing a controlled store could not hold better. The reasoning
belongs in the open; the inventory does not.

So each entry below records the counts, the decision and the method, and names
where the manifest is kept. A manifest is produced by re-running the
characterisation script, which is read-only and committed.

| Deletion | Objects | Manifest |
|---|---|---|
| `rowless-upload-objects-2026-11-05` | 4,234 | held outside the repository; reproducible from `scripts/characterise/rowless-upload-objects.py` against a saved listing |

## rowless-upload-objects-2026-11-05

**Decided by the platform owner on 2026-11-05: delete as development residue.**
**4,234 objects deleted, 0 errors.** Verified by re-listing: 4,390 remained, 0 of
them row-less — exactly the number that had a row.

The evidence is `docs/rowless-upload-objects-2026-11-05.txt`, produced read-only
by `scripts/characterise/rowless-upload-objects.py`. The decisive measure was
the size histogram: **20 distinct sizes across 8,624 objects**, six of them
covering 96.6%. A population of readers' photographs has roughly as many
distinct sizes as objects; this one was the same handful of fixture images
uploaded thousands of times.

Of the 4,234 deleted, exactly **two** were not a repeated fixture size, an empty
file or a test pixel — a 21,807-byte JPEG and a 1,139,428-byte PNG. Both were
included deliberately: having no row, neither was reachable by any reader, by
export, or by erasure, so retaining them served nobody and left personal data
the platform could not have deleted on request.

Method: the exact row-less set was computed by matching every object key's uuid
against the 6,764 `storage_path` values in the production database (no
collisions at 12 hex characters), and the deletion ran from that fixed manifest
with a refusal if its size differed. Verified afterwards by re-listing:
**4,390 objects remain, 0 of them row-less**, which is exactly the number of
objects that had a row.

⚠️ This deletion did NOT address the opposite population — 2,374 rows whose
`storage_path` pointed at an object that no longer exists. That is a different
defect with its own causes and is tracked separately.
