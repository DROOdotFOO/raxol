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

  ## Encoding grammar

  Every persisted value maps to a self-describing, JSON-safe term:

    * `nil`, booleans, numbers, binaries — encoded bare.
    * other atoms — `%{"$a" => "name"}` (tagged strings; restored with
      `String.to_existing_atom/1`, falling back to the raw string if the atom
      no longer exists — safe, never a leak, never a crash).
    * lists — JSON arrays, **all-or-nothing**: a list holding a non-serializable
      element is dropped whole (positional partial-drop would silently reindex).
    * plain maps — `%{"$m" => [[key, value], ...]}` (pairs preserve arbitrary
      key types); per-key drops are recorded, the rest survive.
    * declared structs — `%{"$s" => "Elixir.Mod", "f" => %{"field" => value}}`;
      recursed via the struct's own `Persist.spec/1`.
    * PIDs / Ports / refs / functions / tuples / undeclared structs — never
      encoded; dropped into the manifest.

  See `Raxol.Agent.Snapshot.Persist` for how an app declares its slice.
  """

  alias Raxol.Agent.Snapshot.Persist

  @snapshot_version 1

  # Name-based secret heuristic — a defence-in-depth net so an obvious secret is
  # redacted even when an app forgot to declare it. Matches on field/key names.
  @redact_pattern ~r/secret|password|passwd|token|api[_-]?key|private[_-]?key|credential|mnemonic|seed_phrase/i

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
      {:ok, coerce(decode(data), module)}
    end
  rescue
    e -> {:error, {:load_failed, Exception.message(e)}}
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
       when is_nil(v) or is_boolean(v) or is_number(v) or is_binary(v),
       do: {:keep, v, [], []}

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

  defp encode_fields(fields, persist, redact_set, path) do
    Enum.reduce(fields, {%{}, [], []}, fn {k, val}, {fmap, drops, reds} ->
      cond do
        MapSet.member?(redact_set, k) or sensitive?(k) ->
          {fmap, drops, [redacted_entry(path ++ [k]) | reds]}

        persist != :auto and k not in persist ->
          {fmap, [dropped_entry(path ++ [k], :undeclared_field) | drops], reds}

        true ->
          encode_field(k, val, path, fmap, drops, reds)
      end
    end)
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

  defp decode(%{"$a" => name}) when is_binary(name), do: safe_atom(name)

  defp decode(%{"$s" => mod_str, "f" => fmap})
       when is_binary(mod_str) and is_map(fmap) do
    mod = String.to_existing_atom(mod_str)
    fields = for {k, v} <- fmap, do: {safe_atom(k), decode(v)}
    struct(mod, fields)
  end

  defp decode(%{"$m" => pairs}) when is_list(pairs) do
    Map.new(pairs, fn [k, v] -> {decode(k), decode(v)} end)
  end

  defp decode(list) when is_list(list), do: Enum.map(list, &decode/1)
  defp decode(v), do: v

  # A bare-map encoding restores to a plain map; a caller that knows the target
  # struct module can pass it to rebuild a struct from that map.
  defp coerce(decoded, nil), do: decoded
  defp coerce(%_{} = decoded, _module), do: decoded

  defp coerce(decoded, module) when is_map(decoded) and is_atom(module) do
    fields = for {k, v} <- decoded, do: {atomize(k), v}
    struct(module, fields)
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
    impl = Module.concat(Persist, mod)

    if Code.ensure_loaded?(impl) and function_exported?(impl, :spec, 1) do
      {:declared, impl.spec(struct)}
    else
      :undeclared
    end
  end

  defp sensitive?(k) when is_atom(k) and not is_nil(k) and not is_boolean(k),
    do: sensitive?(Atom.to_string(k))

  defp sensitive?(k) when is_binary(k), do: Regex.match?(@redact_pattern, k)
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
