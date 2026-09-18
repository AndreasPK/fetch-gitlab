# Memory

How to work in this repo: instructions and preferences the user has given, one line each.

- Never open the real store `~/.fetch-gitlab/gitlab.db` for writing, migrate
  it, or run the binary against it. Every run passes
  `--db .ai/scratch/<something>.db`; `sqlite3 -readonly` on the real store is
  allowed.
- `cabal test` rebuilds the library and the test suite but not the executable:
  `cabal build exe:fetch-gitlab` before any live run, and take its path from
  `cabal list-bin fetch-gitlab`.
