# Scoreboard data

Written by `.github/workflows/scoreboard.yml` on master; do not edit by hand.

- `scoreboard/records.jsonl`: one JSON record per published master commit, in
  the order they were published (not commit order). Each line holds the commit
  sha, the Elixir/OTP toolchain it was measured on, the metric values,
  `recorded_at` (UTC) and the CI `run_id`.
- `scoreboard/latest.json`: the record of the newest recorded commit on master.
- `scoreboard/badges/<metric>.json`: shields.io endpoint badges for headline metrics.

Metric ids, labels, units and noise tolerances are defined in
`priv/scoreboard/metrics.json` on master. The measurements are deterministic
counts (BEAM reductions, ANSI frame bytes, memory), not wall-clock timings.
