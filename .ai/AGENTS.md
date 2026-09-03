# Working on fetch-gitlab

Start here when changing the binary. `../agent-summary.md` is for agents that
*use* the binary, `../README.md` for humans; this directory is for the
implementation itself and is part of the repository.

## What lives here

Paths are relative to this directory.

| file | what it is |
|---|---|
| `AGENTS.md` | this file: entry point and index of the topic files |
| `summary/<topic>.md` | one summary per area of the implementation, describing the current state; linked below |
| `log.md` | design decisions, major changes and experiment outcomes, one timestamped entry each; newest last, never rewritten |
| `memory.md` | how to work in this repo: instructions and preferences the user has given, one line each |
| `scratch/` | the agent's own working files; git-ignored, so they outlive the session but never reach a commit |
| `tmp/` | temporary output written for the user to look at; git-ignored |

`log.md`, `memory.md`, `scratch/` and `tmp/` are created on first use.

## Topics

- [summary/Schema.md](summary/Schema.md) — how a store records its schema
  version and patch count, and what `migrate` does at open.
- [summary/implementation.md](summary/implementation.md) — to be written.

A topic file states what is; why is a decision entry in `log.md`
(`grep -n '^## .* — decision:' .ai/log.md`).

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
  above. The log itself is not trimmed.
- **Split** a topic file past 789 lines into narrower topics, each linked
  above.
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
