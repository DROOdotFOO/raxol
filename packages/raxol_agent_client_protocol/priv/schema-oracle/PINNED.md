# Pinned ACP Schema Oracle

Dev/test oracle ONLY (Apache-2.0 upstream) — validate against it in tests; NEVER ship it in
the hex package (excluded via `mix.exs` `:files`).

## Source

- Upstream repo: https://github.com/agentclientprotocol/agent-client-protocol
- Pinned tag: `schema-v1.19.0` (stable release, not a draft/prerelease; published
  2026-07-06T12:35:36Z; commit `e4dcf39453b5a092082e0f662d2be94ac89a4504`)
- Schema version embedded in `meta.json`: `1` (protocol schema major version 1; note the
  upstream repo also carries a parallel `schema/v2/` tree as of this tag — not pinned here,
  since this package targets the v1/stable protocol surface)

## Downloaded artifacts

| File | Upstream path | Download URL |
| --- | --- | --- |
| `v1/schema.json` | `schema/v1/schema.json` | https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/schema-v1.19.0/schema/v1/schema.json |
| `v1/meta.json` | `schema/v1/meta.json` | https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/schema-v1.19.0/schema/v1/meta.json |

Downloaded: 2026-07-16T16:43:00Z

Note: upstream also publishes `schema.unstable.json` / `meta.unstable.json` alongside the
stable pair at this tag — those are explicitly the unstable/draft variants and are NOT
pinned here on purpose.

## SHA256 checksums

```
92c1dfcda10dd47e99127500a3763da2b471f9ac61e12b9bf0430c32cf953796  v1/schema.json
e0bf36f8123b2544b499174197fdc371ec49a1b4572a35114513d56492741599  v1/meta.json
```

Verify with:

```bash
mix acp.schema.verify
```

## Bumping the pin

1. Find the newest stable `schema-vX.Y.Z` tag: `gh api repos/agentclientprotocol/agent-client-protocol/tags --jq '.[].name' | grep '^schema-v'`
2. Confirm it's not a draft/prerelease release.
3. Re-download `schema/v1/schema.json` and `schema/v1/meta.json` at that tag.
4. Recompute SHA256 for both files, update this file and the hashes embedded in
   `lib/mix/tasks/acp.schema.verify.ex`.
