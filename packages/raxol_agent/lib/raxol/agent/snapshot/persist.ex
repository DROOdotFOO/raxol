defprotocol Raxol.Agent.Snapshot.Persist do
  @moduledoc """
  Declares the **persistent slice** of a TEA model — which fields are durably
  serializable and which are secrets to redact.

  This is the declaration half of the model-snapshot contract; the codec lives
  in `Raxol.Agent.Snapshot`. A snapshot is a JSON-safe, versioned envelope that
  a later unit (U9 — Checkpoint) writes into a session's `snapshots/` directory
  as `{journal_offset, model_snapshot}`. Arbitrary TEA models hold PIDs, Ports,
  function refs, ETS refs, and secrets — none JSON-safe, none faithfully
  restorable. This protocol lets an app name the slice that *is*.

  ## Why a protocol (not a behaviour)

  TEA models are frequently bare maps with no owning module (`init/1` commonly
  returns `%{}`). A behaviour can only attach to a module; a protocol dispatches
  on the *value* and — via `@fallback_to_any` — can define conservative default
  behaviour for a map that has no module to host a callback. That is the
  decisive reason this is a protocol with an `Any` fallback.

  ## Declaring a slice

  A struct-backed model opts in with `@derive`:

      defmodule MyModel do
        @derive {Raxol.Agent.Snapshot.Persist,
                 persist: [:count, :title, :history],
                 redact: [:api_key]}
        defstruct [:count, :title, :history, :api_key, :socket_pid]
      end

    * `persist:` — the durable field allowlist. Any field NOT listed is
      **explicitly excluded** — the snapshot records the exclusion in its
      `dropped` manifest, it is never silently mangled. Omit `persist:` (or pass
      `:auto`) for a conservative auto-scan: every field is a candidate, plain
      data survives, non-serializable values (PIDs/Ports/refs/functions) are
      dropped-with-manifest.
    * `redact:` — secret fields. Redacted values never reach the snapshot data;
      they are listed in the `redacted` manifest and restore to their struct
      default. (A name-based heuristic in the codec redacts obvious secrets —
      `api_key`, `password`, `token`, … — even when not declared. See below for
      the full word-list and how it interacts with `persist:`.)

  ## Redaction: the name heuristic vs. your declaration

  Beyond `redact:`, the codec runs a name-based secret heuristic (defense in
  depth for a field you forgot to declare). It matches, on `_`/`-` segment
  boundaries: password / passwd / secret / credential(s) / mnemonic /
  seed_phrase, and name suffixes: token / api_key / apikey / access_key /
  private_key / secret_key. (A few close spellings — creds/cred, privkey, pwd,
  apisecret, ssn — are deliberately NOT included; see the TODO in
  `Raxol.Agent.Snapshot`'s `@redact_segment`/`@redact_suffix` for why.)

  Precedence (highest first) — **the heuristic wins unconditionally**, even
  over an explicit `persist:` listing. This was reviewed and settled: letting
  `persist:` silently override the heuristic would let a real secret, listed
  by typo or oversight (e.g. `persist: [:api_key]`), reach cleartext disk.

    1. explicit `redact:`   — always redacted
    2. name heuristic       — redacts a secret-shaped name even if the field
       is listed in `persist:`
    3. explicit `persist:`  — an unlisted field drops
    4. plain data (`:auto`) — persisted

  If the heuristic redacts a field you explicitly `persist:`-listed, the codec
  logs a `Logger.warning/1` and emits
  `[:raxol, :agent, :snapshot, :persist_redacted_by_heuristic]` telemetry — so
  the mismatch between your declaration and the outcome is loud, not a
  silently-empty field on restore. If that's a genuine false positive, rename
  the field; there is no `persist:`-side override. (The intended future
  escape hatch is a deliberately-ugly `allow_secret_names:` derive opt-out
  that warns on every dump — not `persist:`, and not implemented yet.)

  Bare `seed` is intentionally NOT in the heuristic (it collides with RNG/data
  seeds); redact a real crypto seed explicitly via `redact:`.

  ## Default (no declaration)

  Undeclared values — plain maps, and structs with no `@derive`/`defimpl` —
  fall to the `Any` implementation: `%{persist: :auto, redact: []}`, the
  conservative auto-scan. Note the recursion rule enforced by the codec: a
  *nested* struct is only recursed into if it, too, declares a slice; an
  undeclared nested struct is dropped-with-manifest, loudly.
  """

  @fallback_to_any true

  @typedoc """
  The declared slice for a model.

    * `:persist` — `:auto` (scan every field) or an explicit list of field
      names to persist.
    * `:redact` — field names whose values must never be serialized.
  """
  @type spec :: %{persist: :auto | [atom()], redact: [atom()]}

  @doc "Return the persistent-slice declaration for `model`."
  @spec spec(t()) :: spec()
  def spec(model)
end

defimpl Raxol.Agent.Snapshot.Persist, for: Any do
  @moduledoc """
  Fallback implementation: conservative auto-scan, no redaction.

  Also hosts `__deriving__/3`, which turns
  `@derive {Raxol.Agent.Snapshot.Persist, persist: ..., redact: ...}` into a
  static per-struct implementation.
  """

  defmacro __deriving__(module, _struct, options) do
    persist = Keyword.get(options, :persist, :auto)
    redact = Keyword.get(options, :redact, [])

    validate_persist!(persist, module)
    validate_redact!(redact, module)

    quote do
      defimpl Raxol.Agent.Snapshot.Persist, for: unquote(module) do
        def spec(_model) do
          %{persist: unquote(persist), redact: unquote(redact)}
        end
      end
    end
  end

  # Compile-time validation so a malformed @derive fails loudly at the
  # declaration site rather than silently at snapshot time.
  defp validate_persist!(:auto, _module), do: :ok

  defp validate_persist!(list, _module) when is_list(list) do
    if Enum.all?(list, &is_atom/1),
      do: :ok,
      else: raise(ArgumentError, "persist: must be :auto or a list of atoms")
  end

  defp validate_persist!(other, module) do
    raise ArgumentError,
          "invalid persist: #{inspect(other)} for #{inspect(module)} " <>
            "(expected :auto or a list of field atoms)"
  end

  defp validate_redact!(list, _module) when is_list(list) do
    if Enum.all?(list, &is_atom/1),
      do: :ok,
      else: raise(ArgumentError, "redact: must be a list of atoms")
  end

  defp validate_redact!(other, module) do
    raise ArgumentError,
          "invalid redact: #{inspect(other)} for #{inspect(module)} " <>
            "(expected a list of field atoms)"
  end

  def spec(_model), do: %{persist: :auto, redact: []}
end
