defmodule Raxol.Agent.Snapshot do
  @moduledoc """
  Durable serialization codec for a TEA model's **persistent slice**.

  This is the JSON-safe, restorable counterpart to `Raxol.Debug.Snapshot`
  (which captures whole in-memory `{message, before, after}` cycles for the
  time-travel debugger). Where that snapshot lives and dies in memory, this one
  is written to disk — it is the contract a later unit (U9 — Checkpoint) builds
  `{journal_offset, model_snapshot}` records on. This module is the **contract +
  codec only**: it is pure, with no GenServers and no file IO. U9 owns writing
  envelopes into a session's `snapshots/` directory.

  ## The three operations

    * `dump/1` — model → a versioned, JSON-round-trippable envelope.
    * `load/2` — envelope → the restored model (persistent fields restored,
      everything else at struct/`init` defaults).
    * `persistent_slice/1` — `load(dump(model))`; the durable projection of a
      model, i.e. what survives a checkpoint round-trip.

  ## The envelope

      %{
        v: 1,                       # schema version — this artifact outlives code
        module: "Elixir.MyModel",   # struct module, or nil for a bare-map model
        data: <json-safe encoding>, # the persistent slice
        dropped: [%{"path" => [...], "reason" => "..."}, ...],
        redacted: [%{"path" => [...]}, ...]
      }

  The envelope is intentionally **loud about exclusions**: every field that did
  not make it into `data` is accounted for in `dropped` (non-persistable or
  undeclared) or `redacted` (a secret). Nothing is silently mangled — a reviewer
  reading the manifest sees exactly what the persistent slice omits and why.

  ## The restore property

  `load(dump(model))` equals the model's *persistent slice*, NOT the whole model:

      load(dump(model)) == persistent_slice(model)

  Equality holds on the declared slice only. Non-persistable fields (PIDs,
  Ports, refs, functions), undeclared fields, and secrets come back at their
  struct defaults — by design, not by accident.

  **Precise scope of the equality**: it holds *exactly* for declared struct
  field NAMES, and for string/number/boolean/binary data. Atom *values* and
  bare-map atom *keys* round-trip **best-effort**: an atom already interned at
  load time restores as an atom; one that is not (e.g. an enum value first
  introduced on a later release, loaded on an older/fresh node) restores as its
  raw string name instead — never a crash, never `String.to_atom/1`'s
  unbounded atom-table growth on untrusted disk data.

  The larger real-world blast radius here is **struct field VALUES that are
  atoms**, not just bare-map keys — e.g. `%Model{status: :idle}` restores
  `:idle` as an atom only if something already interned it in the restoring
  VM; a status/enum value first assigned at runtime (never appearing as a
  literal anywhere in that release's source) restores as the string `"idle"`
  instead, silently changing the field's type. Only the struct's *field
  NAMES* are guaranteed via `resolve_struct_module/1` (the struct's module,
  and therefore its `defstruct` field atoms, must already be loaded before
  its `"$s"`-tagged fields are decoded) — the atom *values* it holds carry the
  same best-effort risk as any other atom. This is a fundamental ceiling of a
  JSON-safe, atom-table-DoS-safe codec, not a bug to "fix" by interning on
  load.

  ## Encoding grammar

  Every persisted value maps to a self-describing, JSON-safe term:

    * `nil`, booleans, numbers — encoded bare.
    * valid-UTF-8 binaries — encoded bare; a non-UTF-8 binary is not
      JSON-encodable, so it is tagged `%{"$b64" => base64}` (round-trippable,
      e.g. a terminal buffer or other packed bytes survives the checkpoint
      instead of crashing `Jason.encode!/1` at write time).
    * other atoms — `%{"$a" => "name"}` (tagged strings; restored with
      `String.to_existing_atom/1`, falling back to the raw string if the atom
      no longer exists — safe, never a leak, never a crash). This is the
      best-effort restore path described in "The restore property" above:
      struct field NAMES always resurrect, but an atom VALUE (whether a
      struct field's value, a bare-map value, or a bare-map key) does not if
      it was never interned at load time.
    * lists — JSON arrays, **all-or-nothing**: a list holding a non-serializable
      element is dropped whole (positional partial-drop would silently reindex).
    * plain maps — `%{"$m" => [[key, value], ...]}` (pairs preserve arbitrary
      key types); per-key drops are recorded, the rest survive.
    * declared structs — `%{"$s" => "Elixir.Mod", "f" => %{"field" => value}}`;
      recursed via the struct's own `Persist.spec/1`. On load the module tag is
      validated to name a currently-loaded `Persist` implementation before
      `struct/2` is called. Unlike an atom value or map key, a struct module is
      **not** raw-string-fallback: an unknown or non-`Persist` module tag is a
      typed load error (`{:unknown_struct_module, _}`), never a rebuilt struct.
    * PIDs / Ports / refs / functions / tuples / undeclared structs — never
      encoded; dropped into the manifest.

  See `Raxol.Agent.Snapshot.Persist` for how an app declares its slice.
  """

  require Logger

  alias Raxol.Agent.Snapshot.Persist

  @snapshot_version 1

  # Emitted when the name heuristic redacts a field that the app explicitly
  # listed in `persist:` — i.e. a likely false positive the author didn't
  # intend. The heuristic always wins over persist: (redaction-over-persist is
  # the settled precedence — see encode_fields/4), but a caller relying on
  # that field surviving the checkpoint deserves a loud signal instead of a
  # silently-empty field on restore.
  @telemetry_persist_redacted [:raxol, :agent, :snapshot, :persist_redacted_by_heuristic]

  # Name-based secret heuristic — a defence-in-depth net so an obvious secret is
  # redacted even when an app forgot to declare it. Matches on field/key names,
  # anchored to whole `_`/`-`-delimited segments so normal agent state (token
  # meters and the like) is NOT misclassified as a secret. For an agent runtime
  # `:tokens`, `:token_count`, `:input_tokens`, `:total_tokens`, `:tokenizer`,
  # `:api_key_id`, `:passwords_count`, `:secretary` are ordinary fields; only a
  # field whose NAME is (or ends in) a secret word is redacted.
  #
  # Two rules, because the safe boundary differs by word:
  #
  #   * segment words redact when the word is a complete segment ANYWHERE in the
  #     name (`client_secret`, `db_password`, `seed_phrase`) — these words never
  #     name a benign metric;
  #   * suffix words (`token`, the key family) redact only when the name ENDS
  #     with them, so `access_token`/`api_key` redact while `token_count`,
  #     `input_tokens`, and `api_key_id` do not.
  #
  # Bare `seed` is intentionally NOT in the segment list: it over-matches
  # `random_seed`/`db_seed` and other ordinary ML/RNG state, so the
  # false-positive cost outweighs the marginal defense-in-depth gain. A real
  # crypto seed should be declared via an explicit `redact:`. Keep
  # `seed_phrase`/`mnemonic` — those never name benign data.
  #
  # TODO(deferred — Finding 3, resolved by quorum): candidate additional
  # spellings — creds/cred, privkey, pwd, apisecret, ssn — stay out of the
  # heuristic. Widening this list needs an escape hatch for a field whose NAME
  # matches but isn't secret; the heuristic winning over persist: (Finding 4,
  # settled) means plain `persist:` is NOT that hatch. The intended hatch is a
  # future, deliberately-ugly `allow_secret_names:` derive opt-out (warns on
  # every dump) — not implemented yet. Until then, widening this list has no
  # cheap rescue for a false positive.
  @redact_segment ~r/(?:^|[_-])(?:password|passwd|secret|credentials?|mnemonic|seed[_-]?phrase)(?:$|[_-])/i
  @redact_suffix ~r/(?:^|[_-])(?:token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|secret[_-]?key)$/i

  @type envelope :: %{
          required(:v) => pos_integer(),
          required(:module) => String.t() | nil,
          required(:data) => term(),
          required(:dropped) => [map()],
          required(:redacted) => [map()]
        }

  @doc "The schema version this codec emits."
  @spec version() :: pos_integer()
  def version, do: @snapshot_version

  @doc """
  Serialize `model` into a versioned, JSON-safe envelope.

  Returns `{:ok, envelope}` or `{:error, reason}`. The only `dump` failure is a
  top-level value that is itself non-persistable (e.g. handed a raw PID instead
  of a model) — `{:error, {:not_persistable, reason}}`.
  """
  @spec dump(term()) :: {:ok, envelope()} | {:error, term()}
  def dump(model) do
    case encode(model, []) do
      {:keep, data, dropped, redacted} ->
        {:ok,
         %{
           v: @snapshot_version,
           module: module_name(model),
           data: data,
           dropped: Enum.reverse(dropped),
           redacted: Enum.reverse(redacted)
         }}

      {:drop, reason} ->
        {:error, {:not_persistable, reason}}
    end
  rescue
    e -> {:error, {:dump_failed, Exception.message(e)}}
  end

  @doc """
  Restore a model from an `envelope`.

  Accepts an envelope straight from `dump/1` (atom keys) or one that has
  round-tripped through JSON (string keys). `module`, when given, is the target
  struct module used to rebuild a bare-map encoding into a struct; it is ignored
  when the envelope already carries its own `"$s"` module tag (the common case).

  Returns `{:ok, model}` or a typed `{:error, reason}` — notably
  `{:error, {:unsupported_version, v}}` for an envelope from a future codec,
  never a crash.
  """
  @spec load(envelope() | map(), module() | nil) ::
          {:ok, term()} | {:error, term()}
  def load(envelope, module \\ nil) when is_map(envelope) do
    with {:ok, v} <- fetch(envelope, :v),
         :ok <- check_version(v),
         {:ok, data} <- fetch(envelope, :data) do
      {:ok, coerce(decode(data, 0), module)}
    end
  rescue
    e -> {:error, {:load_failed, Exception.message(e)}}
  catch
    # A tampered/corrupt on-disk envelope is untrusted input (FI-9 tamper
    # class). decode/2 signals structured refusals — unbounded nesting, an
    # unknown/non-Persist struct module, a malformed tag — as throws carrying a
    # typed reason, surfaced here as a typed load error rather than a crash.
    {:snapshot_decode_error, reason} -> {:error, {:load_failed, reason}}
  end

  @doc """
  The durable projection of `model`: `load(dump(model))`.

  This is the slice that survives a checkpoint round-trip — the reference for
  the restore property. Returns `{:ok, slice}` or the underlying error.
  """
  @spec persistent_slice(term()) :: {:ok, term()} | {:error, term()}
  def persistent_slice(model) do
    with {:ok, envelope} <- dump(model) do
      load(envelope, module_atom(model))
    end
  end

  # --- Encoding --------------------------------------------------------------

  # Returns {:keep, encoded, dropped, redacted} | {:drop, reason}.
  # `dropped`/`redacted` accumulate in reverse order (prepended); the public
  # envelope reverses them once.

  defp encode(v, _path)
       when is_nil(v) or is_boolean(v) or is_number(v),
       do: {:keep, v, [], []}

  # Valid-UTF-8 binaries encode bare; a non-UTF-8 binary is not JSON-encodable,
  # so it is base64-tagged (round-trippable) rather than kept bare and crashing
  # Jason at write time.
  defp encode(v, _path) when is_binary(v) do
    if String.valid?(v),
      do: {:keep, v, [], []},
      else: {:keep, %{"$b64" => Base.encode64(v)}, [], []}
  end

  defp encode(v, _path) when is_atom(v),
    do: {:keep, %{"$a" => Atom.to_string(v)}, [], []}

  defp encode(v, _path) when is_pid(v), do: {:drop, :pid}
  defp encode(v, _path) when is_port(v), do: {:drop, :port}
  defp encode(v, _path) when is_reference(v), do: {:drop, :reference}
  defp encode(v, _path) when is_function(v), do: {:drop, :function}
  defp encode(v, _path) when is_tuple(v), do: {:drop, :tuple}
  defp encode(v, path) when is_list(v), do: encode_list(v, path)
  defp encode(%_struct{} = v, path), do: encode_struct(v, path)
  defp encode(v, path) when is_map(v), do: encode_map(v, path)

  # Lists are all-or-nothing: a non-serializable element sinks the whole list
  # rather than silently reindexing the survivors.
  defp encode_list(list, path) do
    Enum.reduce_while(list, {[], [], []}, fn el, {acc, drops, reds} ->
      case encode(el, path) do
        {:keep, enc, d, r} ->
          {:cont, {[enc | acc], d ++ drops, r ++ reds}}

        {:drop, reason} ->
          {:halt, {:drop, {:list_element, reason}}}
      end
    end)
    |> case do
      {:drop, reason} -> {:drop, reason}
      {acc, drops, reds} -> {:keep, Enum.reverse(acc), drops, reds}
    end
  end

  defp encode_map(map, path) do
    {pairs, drops, reds} =
      Enum.reduce(map, {[], [], []}, fn {k, val}, {pairs, drops, reds} ->
        cond do
          sensitive?(k) ->
            {pairs, drops, [redacted_entry(path ++ [k]) | reds]}

          true ->
            encode_pair(k, val, path, pairs, drops, reds)
        end
      end)

    {:keep, %{"$m" => Enum.reverse(pairs)}, drops, reds}
  end

  defp encode_pair(k, val, path, pairs, drops, reds) do
    case {encode(k, path), encode(val, path ++ [k])} do
      {{:keep, ek, _, _}, {:keep, ev, d, r}} ->
        {[[ek, ev] | pairs], d ++ drops, r ++ reds}

      {{:drop, reason}, _} ->
        {pairs, [dropped_entry(path ++ [k], {:bad_key, reason}) | drops], reds}

      {_, {:drop, reason}} ->
        {pairs, [dropped_entry(path ++ [k], reason) | drops], reds}
    end
  end

  defp encode_struct(%mod{} = struct, path) do
    case slice_spec(struct) do
      {:declared, %{persist: persist, redact: redact}} ->
        redact_set = MapSet.new(redact)
        fields = Map.from_struct(struct)
        {fmap, drops, reds} = encode_fields(fields, persist, redact_set, path)
        {:keep, %{"$s" => Atom.to_string(mod), "f" => fmap}, drops, reds}

      :undeclared ->
        {:drop, {:undeclared_struct, module_string(mod)}}
    end
  end

  # Precedence (settled — see @telemetry_persist_redacted above): the name
  # heuristic redacts a secret-shaped field name UNCONDITIONALLY, even when
  # that field is explicitly listed in `persist:`. Rationale: `persist:` is
  # written once at declaration time and can drift as fields are added;
  # letting it silently override the heuristic would let `persist: [:api_key]`
  # (typo, copy-paste, or a genuinely secret field someone forgot to also
  # `redact:`) write a real secret to cleartext disk. The heuristic winning is
  # the safe failure mode — worst case a false positive drops a benign field,
  # which is loud (telemetry + Logger.warning below), never a silent secret
  # leak. A future `allow_secret_names:` derive opt-out (deliberately ugly,
  # warns on every dump) is the intended escape hatch for a genuine false
  # positive — not a plain `persist:` override.
  #
  # A field explicitly declared in BOTH persist: and redact: is redacted
  # (proven by the PidSecretModel `api_key` fixture) — same outcome, no
  # warning needed since the app declared the intent explicitly.
  defp encode_fields(fields, persist, redact_set, path) do
    Enum.reduce(fields, {%{}, [], []}, fn {k, val}, {fmap, drops, reds} ->
      cond do
        MapSet.member?(redact_set, k) ->
          {fmap, drops, [redacted_entry(path ++ [k]) | reds]}

        sensitive?(k) ->
          if persist != :auto and k in persist do
            warn_persist_redacted_by_heuristic(path ++ [k])
          end

          {fmap, drops, [redacted_entry(path ++ [k]) | reds]}

        persist != :auto and k not in persist ->
          {fmap, [dropped_entry(path ++ [k], :undeclared_field) | drops], reds}

        true ->
          encode_field(k, val, path, fmap, drops, reds)
      end
    end)
  end

  defp warn_persist_redacted_by_heuristic(full_path) do
    string_path = stringify_path(full_path)

    Logger.warning(
      "Raxol.Agent.Snapshot: field #{inspect(string_path)} is explicitly " <>
        "listed in persist: but its name matches the secret-redaction " <>
        "heuristic — it is being redacted, not persisted. If it truly holds " <>
        "a secret, this is correct (consider also declaring it in redact: to " <>
        "silence this warning). If it is a false positive, rename the field " <>
        "or file a request to widen the heuristic's escape hatch."
    )

    :telemetry.execute(@telemetry_persist_redacted, %{count: 1}, %{path: string_path})
  end

  defp encode_field(k, val, path, fmap, drops, reds) do
    case encode(val, path ++ [k]) do
      {:keep, enc, d, r} ->
        {Map.put(fmap, Atom.to_string(k), enc), d ++ drops, r ++ reds}

      {:drop, reason} ->
        {fmap, [dropped_entry(path ++ [k], reason) | drops], reds}
    end
  end

  # --- Decoding --------------------------------------------------------------

  # A tampered/corrupt on-disk envelope is untrusted input. decode/2 threads a
  # depth counter and refuses shapes it will not build, throwing a typed
  # reason caught in load/2: nesting past @max_decode_depth, a $s struct-module
  # tag that is not a loaded Persist implementation, and a $a/$b64/$s/$m tag
  # with a malformed body (including a malformed $m INNER PAIR — wrong arity,
  # not just a non-list top-level body). Unknown tags (`$x`, …) still pass
  # through for forward-compat.

  # Deeper than any real model, shallow enough to stop a nesting-bomb envelope
  # before it exhausts the stack.
  @max_decode_depth 64

  defp decode(_v, depth) when depth > @max_decode_depth,
    do: throw({:snapshot_decode_error, :max_depth_exceeded})

  defp decode(%{"$a" => name}, _depth) when is_binary(name), do: safe_atom(name)

  defp decode(%{"$b64" => b64}, _depth) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> throw({:snapshot_decode_error, {:malformed_tag, "$b64"}})
    end
  end

  defp decode(%{"$s" => mod_str, "f" => fmap}, depth)
       when is_binary(mod_str) and is_map(fmap) do
    mod = resolve_struct_module(mod_str)
    fields = for {k, v} <- fmap, do: {safe_atom(k), decode(v, depth + 1)}
    struct(mod, fields)
  end

  defp decode(%{"$m" => pairs}, depth) when is_list(pairs) do
    if Enum.all?(pairs, &match?([_, _], &1)) do
      Map.new(pairs, fn [k, v] ->
        {decode(k, depth + 1), decode(v, depth + 1)}
      end)
    else
      # An inner pair that isn't exactly a 2-element list (e.g. `["a"]` or
      # `["a", 1, 2]`) would otherwise blow up inside the Map.new/2 callback
      # with a raw FunctionClauseError/MatchError — caught by load/2's rescue,
      # but as an unstructured {:load_failed, msg} instead of the same typed
      # {:malformed_tag, "$m"} reason every other corrupt-tag case produces.
      throw({:snapshot_decode_error, {:malformed_tag, "$m"}})
    end
  end

  # A tag marker present but with a malformed body is corruption/tampering, not
  # a forward-compat unknown tag — reject it explicitly rather than letting the
  # raw map survive woven into the restored model.
  defp decode(%{"$a" => _} = v, _depth) when map_size(v) == 1,
    do: throw({:snapshot_decode_error, {:malformed_tag, "$a"}})

  # A $b64 whose body is a non-binary (e.g. `%{"$b64" => 123}`); the
  # non-base64-string case (e.g. `"!!!!"`) is handled by the :error branch above.
  defp decode(%{"$b64" => _} = v, _depth) when map_size(v) == 1,
    do: throw({:snapshot_decode_error, {:malformed_tag, "$b64"}})

  defp decode(%{"$s" => _}, _depth),
    do: throw({:snapshot_decode_error, {:malformed_tag, "$s"}})

  defp decode(%{"$m" => _} = v, _depth) when map_size(v) == 1,
    do: throw({:snapshot_decode_error, {:malformed_tag, "$m"}})

  defp decode(list, depth) when is_list(list),
    do: Enum.map(list, &decode(&1, depth + 1))

  defp decode(v, _depth), do: v

  # Validate a $s module tag before it reaches struct/2. Without this a crafted
  # envelope could steer struct/2 at any loaded struct module and rebuild it
  # with attacker-chosen fields (type-confusion gadget; bounded by
  # to_existing_atom, but downstream code trusts __struct__). The module must
  # resolve to a currently-loaded Persist implementation — the same
  # consolidation-safe probe the dump side uses in slice_spec/1. Unlike an atom
  # VALUE or map key, a struct module is NOT raw-string-fallback: an unknown or
  # non-Persist name is a typed load error, never a silently rebuilt struct.
  defp resolve_struct_module(mod_str) do
    mod = safe_atom(mod_str)

    if is_atom(mod) and persist_impl?(mod) do
      mod
    else
      throw({:snapshot_decode_error, {:unknown_struct_module, mod_str}})
    end
  end

  # A bare-map encoding restores to a plain map; a caller that knows the target
  # struct module can pass it to rebuild a struct from that map.
  defp coerce(decoded, nil), do: decoded
  defp coerce(%_{} = decoded, _module), do: decoded

  # Aligned with the $s decode path (resolve_struct_module/1): a bare-map
  # envelope loaded against an explicit module must also name a currently-
  # loaded Persist implementation before struct/2 is called, never a silently
  # rebuilt struct of an arbitrary caller-supplied module.
  defp coerce(decoded, module) when is_map(decoded) and is_atom(module) do
    if persist_impl?(module) do
      fields = for {k, v} <- decoded, do: {atomize(k), v}
      struct(module, fields)
    else
      throw({:snapshot_decode_error, {:unknown_struct_module, module_string(module)}})
    end
  end

  defp coerce(decoded, _module), do: decoded

  # --- Manifest entries (JSON-safe) ------------------------------------------

  defp dropped_entry(path, reason) do
    %{"path" => stringify_path(path), "reason" => reason_string(reason)}
  end

  defp redacted_entry(path), do: %{"path" => stringify_path(path)}

  defp stringify_path(path), do: Enum.map(path, &key_string/1)

  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(k) when is_binary(k), do: k
  defp key_string(k) when is_number(k), do: to_string(k)
  defp key_string(k), do: inspect(k)

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  # --- Helpers ---------------------------------------------------------------

  defp check_version(@snapshot_version), do: :ok
  defp check_version(v), do: {:error, {:unsupported_version, v}}

  # Envelope keys may be atoms (fresh from dump/1) or strings (post JSON).
  defp fetch(env, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(env, key) -> {:ok, Map.get(env, key)}
      Map.has_key?(env, string_key) -> {:ok, Map.get(env, string_key)}
      true -> {:error, {:missing_key, key}}
    end
  end

  # Resolve a struct's declared slice.
  #
  # We look up the per-struct implementation module (`Persist.<Mod>`) directly
  # rather than through `Persist.impl_for/1` or protocol dispatch. Both consult
  # the *consolidated* dispatch table, which is frozen at the point the defining
  # app is built — a struct that `@derive`s the protocol AFTER consolidation
  # (any downstream app, and every test fixture here) would be invisible to it
  # and silently treated as undeclared. The defimpl module itself is always
  # generated and loadable, so probing it directly is robust to consolidation
  # state. A struct with no such module is genuinely undeclared → auto-scan does
  # not recurse into it; it is dropped-with-manifest.
  defp slice_spec(%mod{} = struct) do
    if persist_impl?(mod) do
      {:declared, Module.concat(Persist, mod).spec(struct)}
    else
      :undeclared
    end
  end

  # The consolidation-safe Persist probe, shared by the dump side (slice_spec/1)
  # and the load side (resolve_struct_module/1): the per-struct implementation
  # module is always generated and loadable even when protocol consolidation
  # froze out a late `@derive`, so probing it directly is robust.
  defp persist_impl?(mod) when is_atom(mod) do
    impl = Module.concat(Persist, mod)
    Code.ensure_loaded?(impl) and function_exported?(impl, :spec, 1)
  end

  defp sensitive?(k) when is_atom(k) and not is_nil(k) and not is_boolean(k),
    do: sensitive?(Atom.to_string(k))

  defp sensitive?(k) when is_binary(k),
    do: Regex.match?(@redact_segment, k) or Regex.match?(@redact_suffix, k)

  defp sensitive?(_), do: false

  # Restore an atom without risking the String.to_atom memory-leak on reload of
  # semi-trusted on-disk data: prefer an existing atom, else keep the string.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp atomize(k) when is_atom(k), do: k
  defp atomize(k) when is_binary(k), do: safe_atom(k)

  defp module_name(model) do
    if is_struct(model), do: module_string(model.__struct__), else: nil
  end

  defp module_atom(model) do
    if is_struct(model), do: model.__struct__, else: nil
  end

  defp module_string(mod), do: Atom.to_string(mod)
end
