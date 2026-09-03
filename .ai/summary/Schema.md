# Schema versions and patches

`meta` holds `schema_version` and `schema_patch_version`; `migrate` and
`checkVersion` in `Store.Sqlite`, `schemaPatches` in `Store.Schema`.

## Invariants

- `schema_version` changes only for a change an older binary would
  misread. Any other version is refused; migrating is not the binary's job.
  It is 1 and has never changed.
- Every additive change — table, column, index, view — is a new entry
  appended to `schemaPatches`, never an edit of an old one: a store may
  already have run it. Base statements must stay `IF NOT EXISTS`.
- A patch is a `SchemaPatch`: statements plus an optional guard query, run
  only if the guard returns a row — how patch 2 drops `has_discussion` from
  stores that have it and skips those created since. Patch 2 is the one
  non-additive patch; log 2026-09-03 "write-through store" says why it is
  not a version bump.
- A column a view references cannot be dropped: a future drop must drop and
  recreate the views in the same patch.
- `migrate` runs the unapplied patches and writes the count last, in one
  `BEGIN IMMEDIATE` transaction. A store counted higher than the binary
  knows is left alone; lowering the count would repeat a non-repeatable
  `ALTER TABLE`.

Decisions: log 2026-09-03 "how does a store record additive schema changes"
and "what does schema_version mean".
