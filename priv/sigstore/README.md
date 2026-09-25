# Pinned Sigstore trusted root

`trusted_root.json` is the Sigstore public-good instance's trusted root: the
Fulcio certificate chains, Rekor log keys and CT log keys that
`Raxol.System.Updater.Provenance` checks release attestations against. It is
compiled into `Raxol.System.Updater.Provenance.TrustedRoot`, so a refreshed
root reaches users only through a (verified) release.

- Source: `gh attestation trusted-root` (gh 2.97.0), which fetches it over
  Sigstore's TUF repository and verifies it. The command prints one JSON line
  per instance; the first is the public-good one (`https://fulcio.sigstore.dev`,
  `https://rekor.sigstore.dev`), the second GitHub's own instance, which
  `raxol-cli` releases do not use.
- Snapshot taken 2026-09-25. It was identical to `targets/trusted_root.json` on
  the `main` branch of <https://github.com/sigstore/root-signing>.

## Refreshing

Sigstore rotates these keys with overlapping `validFor` windows, so refresh
before a window the releases depend on closes, and whenever a release is
signed by a key this file does not list yet:

```sh
gh attestation trusted-root | head -n 1 | jq . > priv/sigstore/trusted_root.json
mix test test/raxol/system/updater/provenance_test.exs
```

Then update the snapshot date above.
