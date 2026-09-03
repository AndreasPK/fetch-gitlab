# Network

`FetchGitLab.RateLimit` (limiter and manager), `FetchGitLab.Logging` (two
loggers), and `waitOutChallenge` with `challengeWaits` in `FetchGitLab.Fetch`.

## Invariants

- The limit lives in the HTTP manager, not in the fetch loops, so the
  library's own pagination and retries are covered. `requestsPerSecond` is
  1.5; two drew gitlab.haskell.org's anti-bot check repeatedly.
- The manager hook is `managerWrapException`, which runs once per request.
  `managerModifyRequest` runs twice (redirect loop) and halves the rate while
  doubling the log. Haddock in RateLimit.hs; pinned by "one turn is taken
  per request".
- A challenge is `GitLabChallengeError`, a constructor of the vendored
  library, never a match on message text. It is the only error retried; the
  ladder aborts the run when exhausted rather than returning. Haddock on
  `waitOutChallenge` says why.
- Both runners are wrapped, including the startup token check: a challenge
  there once killed a run that had fetched nothing.

## Logging

- `--log FILE` gets trace, the terminal keeps info; `runLogT` is given
  `LogTrace` whenever a file is in use and the terminal logger filters on
  `lmLevel` itself. Filtering earlier loses lines from the file.
- One trace line per request, from the manager. The file doubles as the
  record of what was asked of the server; keep the count honest.
