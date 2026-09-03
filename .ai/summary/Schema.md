## Schema versions and patches

A store carries two numbers in `meta`. `schema_version` changes only for a
change an older binary would misread; a store recording any other version is
refused (`checkVersion` in `Store.Sqlite`), and migrating it is a job for
something outside the binary. It is 1 and has never needed to change.
`schema_patch_version` counts the entries of `schemaPatches` (`Store.Schema`)
the store has received. Every addition — a table, a column, an index, a view
— is an entry there, appended and never edited, since a store may already
have run it.

`migrate` runs at open: a store whose count is current costs one read;
otherwise the base statements and the unapplied patches run in one
transaction and the count is written last, so a failure leaves the store as
it was. A store counted higher than the binary knows is left alone — its
extra patches are additive, so the binary reads it fine, and lowering the
count would make the newer binary repeat a patch such as `ALTER TABLE ...
ADD COLUMN` that cannot run twice. A store from before the count existed is
at patch 0; the pipeline statements are `IF NOT EXISTS`, so one that already
has the tables runs patch 1 as a no-op.
