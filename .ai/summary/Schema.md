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
- `migrate` runs the unapplied patches and writes the count last in one
  transaction. A store counted higher than the binary knows is left alone.
  Lowering it would repeat a non-repeatable `ALTER TABLE`.

Decisions: log 2026-09-03 "how does a store record additive schema changes"
and "what does schema_version mean".
