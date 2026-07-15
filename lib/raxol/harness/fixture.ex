defmodule Raxol.Harness.Fixture do
  @moduledoc """
  Loader + decode shim for versioned JSONL harness fixtures.

  A fixture is the recorded *bus stream* (both tiers — ephemeral
  `item_delta` traffic included), not the durable journal
  (`docs/proposals/in-flight/harness-ui-testing/06-projection.md` §1.1).
  Line 1 is a header record; every subsequent line is one serialized
  `%Envelope{}` per `harness-spec-protocol.md` §2/§3.

  `decode/1` is the stand-in for the real agent-lane codec (which does not
  exist in code yet — `harness-spec-protocol.md` §6 describes the eventual
  single validation seam; `Raxol.Agent.Contract` from PR #542 is the
  shipped v0 slice). It is loud-reject: a structurally invalid line
  produces a typed `Raxol.Harness.Fixture.DecodeError`, never a
  best-effort partial parse. `load/1` upcasts every envelope on read via
  `Raxol.Harness.Fixture.Upcast`.
  """

  alias Raxol.Harness.Fixture.{
    DecodeError,
    Envelope,
    Event,
    Header,
    Session,
    Upcast
  }

  @schema "harness-fixture/1"
  @current_envelope_version Upcast.current_version()

  @header_kinds %{"golden" => :golden, "adversarial" => :adversarial}
  @envelope_kinds %{"event" => :event, "command" => :command}
  @families %{"loop" => :loop, "meta" => :meta}
  @tiers %{"ephemeral" => :ephemeral, "durable" => :durable}
  @scopes %{"session" => :session, "global" => :global}
  @trusts %{"trusted" => :trusted, "tainted" => :tainted}

  # family :loop vocabulary, harness-spec-protocol.md §3
  @loop_types %{
    "turn_started" => :turn_started,
    "item_started" => :item_started,
    "item_delta" => :item_delta,
    "item_completed" => :item_completed,
    "turn_completed" => :turn_completed,
    "state_change" => :state_change,
    "approval_requested" => :approval_requested,
    "error" => :error,
    "idle" => :idle
  }

  # family :meta vocabulary (the probe population), harness-spec-protocol.md §3
  @meta_types %{
    "gate_decision" => :gate_decision,
    "extract" => :extract,
    "residual" => :residual,
    "calibrate" => :calibrate,
    "verdict" => :verdict,
    "research" => :research,
    "promote" => :promote
  }

  @type decoded :: Header.t() | Envelope.t()

  @doc """
  Decode one raw JSONL line into a `Header` or an `Envelope`.

  Validates shape strictly: the top-level `Event.type` is checked against
  the known `family`-scoped vocabulary (an unknown top-level type is a
  version mismatch — a loud error per protocol §6). Vocabulary *within* a
  known event (e.g. an unrecognized `item_type` inside a payload) is
  deliberately NOT validated here — that is a projection-level, graceful-
  opaque-render concern (06-projection §4.6, N-FWD), out of scope for the
  decode seam.
  """
  @spec decode(String.t()) :: {:ok, decoded()} | {:error, DecodeError.t()}
  def decode(line) when is_binary(line) do
    with {:ok, map} <- parse_json(line),
         {:ok, map} <- ensure_object(map),
         {:ok, record} <- fetch_record(map) do
      decode_record(record, map)
    end
  end

  @doc """
  Load a fixture file: decode every line, upcast each envelope's body to
  the current schema, and assemble a `Session`. The header must be line 1
  and unique; any envelope line failing `decode/1` halts the load loud
  (the offset in the resulting error is the 1-based line number).

  Offset integrity: interior blank lines are a `:blank_line` error (they
  would desync `offset` from the physical line number); a trailing final
  newline is tolerated.
  """
  @spec load(Path.t()) :: {:ok, Session.t()} | {:error, DecodeError.t()}
  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        load_lines(contents, path)

      {:error, reason} ->
        {:error, %DecodeError{reason: :file_error, details: {path, reason}}}
    end
  end

  defp load_lines(contents, path) do
    contents
    |> String.split("\n")
    |> drop_trailing_blanks()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, nil, []}, &load_line/2)
    |> finalize_session(path)
  end

  # A trailing final newline (or several) is tolerated; INTERIOR blank
  # lines are a loud `:blank_line` error so that `offset == physical line
  # number` holds by construction — the whole replay-from-offset story
  # keys off that identity.
  defp drop_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp load_line({"", offset}, {:ok, _header, _envelopes}) do
    {:halt, {:error, %DecodeError{reason: :blank_line, offset: offset}}}
  end

  defp load_line({line, offset}, {:ok, header, envelopes}) do
    case decode(line) do
      {:ok, %Header{} = h} ->
        load_header(h, offset, header, envelopes)

      {:ok, %Envelope{} = e} ->
        load_envelope(e, offset, header, envelopes)

      {:error, %DecodeError{} = err} ->
        {:halt, {:error, %{err | offset: offset}}}
    end
  end

  # A header-shaped line is only ever seen with `header == nil` when it's
  # genuinely line 1 (any earlier non-header line at offset 1 would have
  # already halted via `load_envelope`'s `envelope_before_header` guard),
  # so `header != nil` here means exactly one thing: a second header-
  # shaped line somewhere later in the file.
  defp load_header(_h, offset, header, _envelopes) when not is_nil(header) do
    {:halt, {:error, %DecodeError{reason: :duplicate_header, offset: offset}}}
  end

  defp load_header(h, _offset, _header, envelopes),
    do: {:cont, {:ok, h, envelopes}}

  defp load_envelope(_e, offset, nil, _envelopes) do
    {:halt,
     {:error, %DecodeError{reason: :envelope_before_header, offset: offset}}}
  end

  defp load_envelope(e, offset, header, envelopes) do
    envelope = %{e | offset: offset}
    upcasted = Upcast.to_current(header.envelope_v, envelope)
    {:cont, {:ok, header, [upcasted | envelopes]}}
  end

  defp finalize_session({:error, _} = err, _path), do: err

  defp finalize_session({:ok, nil, _envelopes}, _path) do
    {:error, %DecodeError{reason: :missing_header}}
  end

  defp finalize_session({:ok, header, envelopes}, path) do
    {:ok,
     %Session{header: header, envelopes: Enum.reverse(envelopes), path: path}}
  end

  # -- record dispatch --------------------------------------------------

  defp decode_record("header", map), do: decode_header(map)
  defp decode_record("envelope", map), do: decode_envelope(map)

  defp decode_record(other, _map) do
    {:error, %DecodeError{reason: :unknown_record_type, details: other}}
  end

  # -- header -------------------------------------------------------------

  defp decode_header(map) do
    with {:ok, schema} <- fetch_string(map, "schema"),
         :ok <- check_schema(schema),
         {:ok, envelope_v} <- fetch_pos_integer(map, "envelope_v"),
         {:ok, harness_version} <- fetch_string(map, "harness_version"),
         {:ok, backend} <- fetch_string(map, "backend"),
         {:ok, model} <- fetch_string(map, "model"),
         {:ok, config_hash} <- fetch_string(map, "config_hash"),
         {:ok, kind} <- fetch_enum(map, "kind", @header_kinds),
         {:ok, pathologies} <- fetch_optional_pathologies(map) do
      {:ok,
       %Header{
         schema: schema,
         envelope_v: envelope_v,
         harness_version: harness_version,
         backend: backend,
         model: model,
         config_hash: config_hash,
         kind: kind,
         recorded_at: Map.get(map, "recorded_at"),
         name: Map.get(map, "name"),
         notes: Map.get(map, "notes"),
         pathologies: pathologies
       }}
    end
  end

  # Optional machine-readable corruption index for adversarial fixtures:
  # `"pathologies": [{"class": "late_delta_after_seal", "offset": 6}, …]`.
  # Downstream tests seek named corruptions via `Session.pathologies/1`
  # instead of hardcoding line numbers.
  defp fetch_optional_pathologies(map) do
    case Map.fetch(map, "pathologies") do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        decode_pathologies(list)

      {:ok, other} ->
        {:error,
         %DecodeError{
           reason: :invalid_field_type,
           details: {"pathologies", other}
         }}
    end
  end

  defp decode_pathologies(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      %{"class" => class, "offset" => offset}, {:ok, acc}
      when is_binary(class) and is_integer(offset) and offset > 0 ->
        {:cont, {:ok, [%{class: class, offset: offset} | acc]}}

      other, {:ok, _acc} ->
        {:halt,
         {:error,
          %DecodeError{
            reason: :invalid_field_value,
            details: {"pathologies", other}
          }}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp check_schema(@schema), do: :ok

  defp check_schema(other),
    do: {:error, %DecodeError{reason: :unsupported_schema, details: other}}

  # -- envelope -------------------------------------------------------------

  defp decode_envelope(map) do
    with {:ok, v} <- fetch_pos_integer(map, "v"),
         :ok <- check_envelope_version(v),
         {:ok, session_id} <- fetch_string(map, "session_id"),
         {:ok, kind} <- fetch_enum(map, "kind", @envelope_kinds),
         {:ok, body_map} <- fetch_map(map, "body"),
         {:ok, body} <- decode_event(body_map) do
      {:ok, %Envelope{v: v, session_id: session_id, kind: kind, body: body}}
    end
  end

  defp check_envelope_version(v) when v <= @current_envelope_version, do: :ok

  defp check_envelope_version(v) do
    {:error, %DecodeError{reason: :unsupported_envelope_version, details: v}}
  end

  defp decode_event(map) do
    with {:ok, id} <- fetch_non_neg_integer(map, "id"),
         {:ok, ts} <- fetch_integer(map, "ts"),
         {:ok, family} <- fetch_enum(map, "family", @families),
         {:ok, type} <- fetch_event_type(map, family),
         {:ok, tier} <- fetch_enum(map, "tier", @tiers),
         {:ok, payload} <- fetch_map(map, "payload"),
         {:ok, scope} <- fetch_optional_enum(map, "scope", @scopes),
         {:ok, provenance} <- fetch_optional_provenance(map, "provenance") do
      {:ok,
       %Event{
         id: id,
         turn_id: Map.get(map, "turn_id"),
         ts: ts,
         family: family,
         type: type,
         tier: tier,
         scope: scope,
         provenance: provenance,
         payload: payload
       }}
    end
  end

  defp fetch_event_type(map, family) do
    vocabulary = event_vocabulary(family)

    with {:ok, str} <- fetch_string(map, "type") do
      case Map.fetch(vocabulary, str) do
        {:ok, atom} ->
          {:ok, atom}

        :error ->
          {:error,
           %DecodeError{reason: :unknown_event_type, details: {family, str}}}
      end
    end
  end

  defp event_vocabulary(:loop), do: @loop_types
  defp event_vocabulary(:meta), do: @meta_types

  defp fetch_optional_provenance(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, %{} = prov} ->
        with {:ok, source} <- fetch_string(prov, "source"),
             {:ok, trust} <- fetch_enum(prov, "trust", @trusts) do
          {:ok, %{source: source, trust: trust}}
        end

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}
    end
  end

  defp fetch_optional_enum(map, key, enum_map) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, str} when is_binary(str) ->
        fetch_enum_value(str, enum_map, key)

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}
    end
  end

  # -- generic JSON scaffolding --------------------------------------------

  defp parse_json(line) do
    case Jason.decode(line) do
      {:ok, map} ->
        {:ok, map}

      {:error, reason} ->
        {:error, %DecodeError{reason: :invalid_json, details: reason}}
    end
  end

  defp ensure_object(%{} = map), do: {:ok, map}

  defp ensure_object(other),
    do: {:error, %DecodeError{reason: :not_an_object, details: other}}

  defp fetch_record(map) do
    case Map.fetch(map, "record") do
      {:ok, str} when is_binary(str) ->
        {:ok, str}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {"record", other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_record_type}}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) ->
        {:ok, v}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_field, details: key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, %{} = v} ->
        {:ok, v}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_field, details: key}}
    end
  end

  defp fetch_pos_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_integer(v) and v > 0 ->
        {:ok, v}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_field, details: key}}
    end
  end

  defp fetch_non_neg_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_integer(v) and v >= 0 ->
        {:ok, v}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_field, details: key}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_integer(v) ->
        {:ok, v}

      {:ok, other} ->
        {:error,
         %DecodeError{reason: :invalid_field_type, details: {key, other}}}

      :error ->
        {:error, %DecodeError{reason: :missing_field, details: key}}
    end
  end

  defp fetch_enum(map, key, enum_map) do
    case fetch_string(map, key) do
      {:ok, str} -> fetch_enum_value(str, enum_map, key)
      error -> error
    end
  end

  defp fetch_enum_value(str, enum_map, field) do
    case Map.fetch(enum_map, str) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         %DecodeError{reason: :invalid_field_value, details: {field, str}}}
    end
  end
end
