# Working on fetch-gitlab

Start here when changing the binary. `../agent-summary.md` is for agents that
*use* the binary, `../README.md` for humans; this directory is for the
implementation itself and is part of the repository.

## What lives here

Paths are relative to this directory.

| file | what it is |
|---|---|
| `AGENTS.md` | this file: entry point and index of the topic files |
| `summary/<topic>.md` | one map per area of the implementation: where things are, what must stay true, what to watch for; linked below |
| `log.md` | design decisions, major changes and experiment outcomes, one timestamped entry each; newest last, never rewritten |
| `memory.md` | how to work in this repo: instructions and preferences the user has given, one line each |
| `scratch/` | the agent's own working files; git-ignored, so they outlive the session but never reach a commit |
| `tmp/` | temporary output written for the user to look at; git-ignored |

`log.md`, `memory.md`, `scratch/` and `tmp/` are created on first use.

## Topics

- [summary/modules.md](summary/modules.md) — module map, the option
  grammar, building and what the tests cover.
- [summary/fetch.md](summary/fetch.md) — the order of a run, paged record
  fetching, what stays in memory, not asking twice, `--clear-timestamp`,
  `--pipelines`.
- [summary/network.md](summary/network.md) — rate limiting and the manager
  hook, anti-bot challenge waits, request logging.
- [summary/store.md](summary/store.md) — `StoreBackend`, the SQLite backend,
  how an object is split across tables, the pipeline tables.
- [summary/Schema.md](summary/Schema.md) — how a store records its schema
  version and patch count, and what `migrate` does at open.
- [summary/lock.md](summary/lock.md) — the per-store lock file and its two
  GHC-specific subtleties.
- [summary/vendored-gitlab-haskell.md](summary/vendored-gitlab-haskell.md) —
  the patches and additions to the vendored library.

## What a topic file is for

A topic file saves code reads and directs the ones that remain. It is a map,
not a manual, and it covers one area of the implementation by saying:

- **where things are** — which module and function owns each concern, so
  the reader knows what to open and what to skip;
- **invariants that span modules** — what one file relies on another
  keeping true, which no single haddock shows;
- **traps** — what looks reasonable and is wrong, and the test that pins it;
- **decisions that still constrain choices** — one line each, stating the
  constraint and linking the `log.md` entry that holds the reasoning.

A line earns its place if it saves a file read or prevents a wrong
assumption. Three tests for a sentence:

- If it restates what the code or its comment already says, replace it with
  the symbol name. The reader has grep and will read the real thing.
- If it explains why, it is a decision: one line here with the constraint,
  the reasoning in `log.md` or in the code comment where it already lives.
- If it is a number, it stays only if it bounds a design choice — a cap, a
  limit, a size to extrapolate from — not as the record of a measurement
  that doesn't motivate a design decision.

Not a topic file: the sequence of what a function does, the history of how
the code got here, or measurements and their commands. Those are the code,
`log.md` and `scratch/` respectively.

A topic needs to be concise. Once it grows above 90 lines the additional size
needs to be strongly motivated.

## How to use it

- **Read** this file, `memory.md`, and the topic files that touch what you
  are changing.
- **Log for a later reader.** `log.md` is committed. An entry is a design
  decision, a change that alters what a topic file says, or an experiment's
  outcome — results and numbers, not the commands run — under
  `## <ISO 8601 timestamp> — <what>`, e.g. `## 2026-09-03T10:00+02:00 — …`.
  Routine work goes in the commit message, working notes in `scratch/`.
- **Decisions** are entries headed `— decision: <question>` giving the
  decision, the reason and the files it touches; `log.md` has examples.
  Overturning one is a new entry; old entries are never edited.
- **Fold, don't accumulate.** When a log entry changes what a topic file
  should say, update that file, or start one under `summary/` and link it
  above. Fold the constraint, not the story: the log keeps the reasoning and
  is never trimmed. When a topic file passes a screen, apply the three tests
  above before splitting it.
- **Persist instructions** the user gives about working in this repo as one
  line each in `memory.md`, not in the agent's global memory.
- **`scratch/` for agent work** — intermediate files, test databases, drafts
  — so later sessions on this machine find them. **`tmp/` for output meant
  for the user** — a report, a diff, a listing. Fold anything worth keeping
  into a topic file.

# Human facing documentation

Human time is valuable, so make two passes over documentation aimed at
humans — `README.md`, `--help` text — but not the files here: write it, then
cut what is useless or redundant.
