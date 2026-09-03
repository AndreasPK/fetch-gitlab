# Modules, options, tests

| Module | Owns | Topic |
| --- | --- | --- |
| `Options` | parser, `Command`, `Options`, `Backend` | below |
| `Since` | `--since` grammar and resolution | |
| `Fetch` | `run`, records, discussions, pipelines, challenge wait | [fetch.md](fetch.md), [network.md](network.md) |
| `ClearTimestamp` | `--clear-timestamp` | [fetch.md](fetch.md) |
| `Store` | `Record`, `Entry`, `Discussion`, merge, staleness | [store.md](store.md) |
| `Store.Class` | `StoreBackend` | [store.md](store.md) |
| `Store.Backend` | `--backend`/`--db` to an open store and lock paths | [store.md](store.md) |
| `Store.Sqlite` | the backend, `migrate` | [store.md](store.md), [Schema.md](Schema.md) |
| `Store.Schema`, `.Pipeline` | tables, `schemaPatches` | [store.md](store.md), [Schema.md](Schema.md) |
| `Store.Schema.Types` | `LiftSpec`, split/splice | [store.md](store.md) |
| `Lock` | store locks | [lock.md](lock.md) |
| `Logging`, `RateLimit` | loggers, limiter, manager | [network.md](network.md) |

All under `FetchGitLab.`; `app/Main.hs` only dispatches.

## Options

- `--clear-timestamp` shares one grammar with fetching rather than being a
  parser alternative: optparse-applicative backtracks only out of a branch
  that consumed nothing, so alternatives sharing `--db` parse
  order-sensitively. Cost: fetch-only flags are accepted and ignored.

## Tests

`cabal test`; fixtures are real GitLab responses in `test/data/`, no
network. Test names in `test/Main.hs` are sentences; grep for the invariant
you are touching before changing it. The lock group re-runs the test
executable with `--hold-lock` for the cross-process case.
