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
- Patch 3 (`refStatements`) also drops the unused `notes_id` index; the
  base schema no longer creates it.
- A patch that adds an index ends with `ANALYZE`; patch 3 (`refStatements`)
  is the first. Without statistics the planner prefers the `kind` prefix of
  a primary key over any index, however selective. `ANALYZE` sees nothing in
  a fresh (empty) store, so `closeSqliteStore` also runs `PRAGMA optimize`.
- Patch 4 (`viewStatements`, `Store.Schema.Views`) adds the seven `view_*`
  views. They stand on the `ref` indexes and on the statistics from patch 3:
  the kind filters inside them are plain `kind = '…'`, which without
  `sqlite_stat1` sends the planner down the `kind` prefix of `note_users`
  for every query shape. A view is frozen in the store: changing one is a
  later patch of `DROP VIEW IF EXISTS` + `CREATE VIEW`. Views never go in
  the base schema, since SQLite resolves a view's columns at create time and
  the base statements run before the patches that add columns.
- Patch 5 (`jobLogAndExpiryStatements`, `Store.Schema.Pipeline`) adds
  `job_logs` and the `jobs_delete_log` trigger, then `expire_at` on
  `pipelines` and `jobs` plus the `UPDATE` that dates the rows a store
  already holds, then `ciViewStatements` (`Store.Schema.Views`):
  `view_mr_ci_status` and `view_jobs`, last because they read `job_logs`
  and `expire_at`. A trigger is frozen in the store like a view. Not
  repeatable, like patch 3: `ADD COLUMN` runs once, and the column is in
  neither the base schema nor patch 1, which is why it must not be added to
  `pipelineSchemaStatements`. `ADD COLUMN` cannot be `NOT NULL` without a
  constant default, so the column is nullable and NULL means "not expired".
  A patch may rely on the tables of earlier patches, so a test fixture that
  claims a patch level must really be at it ("a store at the old schema
  loses has_discussion" and "a store at patch 1 gains expire_at" both run
  patch 1's statements for that reason).
- `migrate` runs the unapplied patches and writes the count last, in one
  `BEGIN IMMEDIATE` transaction. A store counted higher than the binary
  knows is left alone; lowering the count would repeat a non-repeatable
  `ALTER TABLE`.

Decisions: log 2026-09-03 "how does a store record additive schema changes"
and "what does schema_version mean".
