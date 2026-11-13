# Shared boundary conformance vectors

Single source of truth for the two boundary confinements. These are
**data-only** JSON files, free of any Elixir or host coupling, so they can be
copied byte-for-byte into another package's test tree.

| File | Drives | Consumers |
| ---- | ------ | --------- |
| `path_reject_vectors.json` | `Raxol.Core.Boundary.Path.confine/3` must REJECT | raxol_core **and** the Agent Client Protocol package's `FsSandbox` |
| `path_accept_vectors.json` | `Raxol.Core.Boundary.Path.confine/3` must ACCEPT | raxol_core **and** the Agent Client Protocol package's `FsSandbox` |
| `term_text_vectors.json` | `Raxol.Core.Boundary.TermText.sanitize/2` | raxol_core only (UI/terminal lane) |

## The drift guard

`raxol_agent_client_protocol` keeps its own `FsSandbox` and does not depend on
`raxol_core`. To keep the two implementations from forking, **both bind to
these same path vectors**:

- raxol_core runs them in `test/raxol/core/boundary/path_test.exs`.
- The Agent Client Protocol package copies `path_reject_vectors.json` and
  `path_accept_vectors.json` verbatim into its own test tree and asserts its
  `FsSandbox.resolve/2` agrees:
  - map `FsSandbox`'s `Error` `data.reason` onto the vector's `expect` atom
    (`path_traversal` / `symlink_escape` / `too_many_symlinks`);
  - **skip** any vector carrying `ref_format`: the ref-shape gate is a
    `Path.confine/3`-only feature `FsSandbox` does not implement.

A divergence between the two implementations then shows up as a red test in one
of the packages, never as an unnoticed security fork. Change a path vector and
you must update both copies (and the `FsSandbox` moduledoc's duplicate-marker
line), or neither.

## Schema

### `path_*_vectors.json`

```jsonc
{
  "root": "root",              // dir under the tmp base used as confinement root ("." = base)
  "requested": "../etc/x",     // untrusted ref passed to confine/3
  "ref_format": "^...$",       // OPTIONAL regex source for the ref-shape gate
  "setup": [                   // FS fixture materialized under the tmp base (paths relative to base)
    { "dir": "root" },
    { "file": "outside/secret.txt", "content": "..." },
    { "symlink": "root/link", "target": "../outside" }
  ],
  "expect": "ok"               // "ok" (accept file) or a rejection reason atom (reject file)
}
```

Additionally, for every **reject** vector the surrounding site test must prove
the outside target was neither read nor created.

### `term_text_vectors.json`

```jsonc
{
  "input_hex": "1b5b33316d...",  // lowercase hex of the input binary
  "allow": [9, 10],              // OPTIONAL C0 byte values passed as opts `allow:`
  "expect_hex": "68656c6c6f"     // lowercase hex of the intended output binary
}
```

Control bytes are hex-encoded so the fixtures stay valid, portable JSON.
