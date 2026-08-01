defmodule Raxol.Agent.Command do
  @moduledoc """
  Harness command channel — the inbound half of the harness protocol.

  `Raxol.Agent.Contract` is the outbound half (core → surface): observable
  loop steps become `Contract.Event`s emitted through `SessionStreamer`. This
  module is the mirror image (surface → core): a subscriber's typed request to
  drive the session — start a turn, interrupt it, (later) attach/seek a
  read-model.

  Conforms to the harness command contract described in
  `docs/harness/architecture.md` ("The event contract"); see "The one
  validation seam" below for the decode rules this module enforces.

  ## Vocabulary (v0)

    * `:prompt`    — start a turn; payload `%{text}` (required, non-empty),
      optional `:attachments`. The primary population's entry point.
    * `:interrupt` — supervised kill of the running turn (AD-1); payload `%{}`,
      optionally `%{turn_id: ...}`. The real cancel lands in U5.
    * `:attach`    — subscribe + replay durable events from an offset; payload
      `%{from_offset: integer, history_policy: atom}`. Routes to
      `Raxol.Agent.Reattach` (`:replay`/`:live`; `:snapshot` unsupported).
    * `:seek`      — time-travel a read-model to a journal offset; payload
      `%{offset: integer}`. Folds durable events with id <= offset into the
      `Raxol.Harness.Projection` block read-model.
    * `:steer`     — redirect a running turn without killing it; payload
      `%{text: binary, expected_turn_id: term}` (both required), optional
      `:client_msg_id`. Decodes and routes; EXECUTING it (the compare-and-swap
      against the running turn, `Raxol.Agent.Steer.resolve/2`) is the session
      runtime's integration, still pending.

  `:approval_decision` and `:detach` from the full protocol table attach
  behind this same seam in later steps; the codec grows, the shape does not.

  ## The one validation seam

  `decode/1` is the single place wire/term input becomes a typed `%Command{}`.
  It is **loud**: malformed JSON, a non-map, an unknown/missing `type`, or a
  missing/empty required payload field is a typed `{:error, {:invalid_command,
  reason}}` — never a best-effort partial (COMPASS: string-level leniency is
  where enforcement fails 60–87%). It **never raises** on bad input.

  ## Routing seam

  `route/2` dispatches a decoded command into a live session. In v0 it is a
  pure dispatcher: it returns a typed **action tuple** the session runtime
  executes, and — when the session carries a `:pid` — also delivers that action
  as a `{:harness_command, action}` OTP message to the session process (the
  U5 turn-supervisor pattern-matches it). The `:prompt` action
  (`{:start_turn, session_id, payload}`) is what the session runtime turns into
  a `Raxol.Agent.Contract.pump/3` over a `Raxol.Agent.Stream.react/2` run — the
  exact path `mix raxol.p` already drives. Actually spawning that turn subtree
  is U5's job; here we validate and dispatch.
  """

  alias Raxol.Agent.Code.EventCodec
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Reattach
  alias Raxol.Harness.Projection

  @enforce_keys [:type]
  defstruct type: nil, payload: %{}

  @type type :: :prompt | :interrupt | :attach | :seek | :steer | :approval_decision

  @type t :: %__MODULE__{
          type: type(),
          payload: map()
        }

  @typedoc """
  A live session handle. Either a bare `session_id` binary, or a map carrying
  at least `:session_id` and optionally a `:pid` to receive dispatched actions.
  """
  @type session ::
          binary()
          | %{optional(:session_id) => term(), optional(:pid) => pid()}

  @type reason :: atom() | {atom(), term()}

  @type action ::
          {:start_turn, term(), map()}
          | {:interrupt, term(), map()}
          | {:steer, term(), map()}
          | {:approval_decision, term(), map()}

  # Whitelisted string → atom for the `type` field. Never String.to_atom/1 on
  # user input (unbounded atom table growth).
  @types %{
    "prompt" => :prompt,
    "interrupt" => :interrupt,
    "attach" => :attach,
    "seek" => :seek,
    "steer" => :steer,
    "approval_decision" => :approval_decision
  }

  # Whitelisted history policies for `attach`.
  @history_policies %{
    "replay" => :replay,
    "live" => :live,
    "snapshot" => :snapshot
  }

  @doc """
  Decode wire/term input into a `%Command{}` — the single validation seam.

  Accepts a JSON string or a plain map. The canonical shape is
  `%{"type" => t, "payload" => %{...}}`; string and atom keys both work.
  Returns `{:ok, %Command{}}` or `{:error, {:invalid_command, reason}}`.

  Never raises on bad input.

  ## Examples

      iex> Raxol.Agent.Command.decode(~s({"type":"prompt","payload":{"text":"hi"}}))
      {:ok, %Raxol.Agent.Command{type: :prompt, payload: %{text: "hi"}}}

      iex> Raxol.Agent.Command.decode("{not json")
      {:error, {:invalid_command, {:malformed_json, "unexpected byte at position 1"}}}

      iex> Raxol.Agent.Command.decode(%{"type" => "prompt", "payload" => %{}})
      {:error, {:invalid_command, :missing_text}}
  """
  @spec decode(String.t() | map() | term()) ::
          {:ok, t()} | {:error, {:invalid_command, reason()}}
  def decode(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, map} when is_map(map) ->
        decode(map)

      {:ok, _other} ->
        {:error, {:invalid_command, :not_a_map}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_command, {:malformed_json, decode_error_message(error)}}}
    end
  end

  def decode(map) when is_map(map) and not is_struct(map) do
    with {:ok, type} <- fetch_type(map),
         payload = fetch_payload(map),
         {:ok, validated} <- validate(type, payload) do
      {:ok, %__MODULE__{type: type, payload: validated}}
    end
  end

  def decode(_other), do: {:error, {:invalid_command, :not_a_command}}

  @doc """
  Dispatch a decoded command into a live `session`.

  * `:prompt`    → `{:start_turn, session_id, payload}` — the session runtime
    pumps a `Raxol.Agent.Stream.react/2` run through `Contract.pump/3`.
  * `:interrupt` → `{:interrupt, session_id, payload}` — the supervised-kill
    seam (U5).
  * `:steer`     → `{:steer, session_id, payload}` — dispatched the same way;
    the session runtime resolves the compare-and-swap against the running
    turn (`Raxol.Agent.Steer.resolve/2`).
  * `:attach`    → subscribes the session pid to the durable stream via
    `Raxol.Agent.Reattach.attach/4` and replays from `from_offset`
    (`history_policy: :replay`) or from the live watermark (`:live`); records
    arrive as `{:reattach_live, session_id, record}`. `:snapshot` is not yet
    supported (`{:error, {:unsupported_history_policy, :snapshot}}`).
  * `:seek`      → `{:ok, projection}` — folds durable events with id <= offset
    into the `Raxol.Harness.Projection` block read-model (read-side, pure);
    `{:error, :damaged}` on a corrupt journal.

  When `session` carries a `:pid`, the action is also delivered to that process
  as `{:harness_command, action}` (the real OTP dispatch); the action tuple is
  returned regardless, for synchronous callers and tests. (`:attach` and `:seek`
  are the exceptions — each performs its read-side operation directly and
  returns the result.)
  """
  @spec route(t(), session()) :: action() | {:ok, term()} | {:error, term()}
  def route(%__MODULE__{type: :prompt, payload: payload}, session) do
    dispatch(session, {:start_turn, session_id(session), payload})
  end

  def route(%__MODULE__{type: :interrupt, payload: payload}, session) do
    dispatch(session, {:interrupt, session_id(session), payload})
  end

  def route(%__MODULE__{type: :steer, payload: payload}, session) do
    dispatch(session, {:steer, session_id(session), payload})
  end

  # The live-approval answer. Delivered to the session runtime as
  # `{:approval_decision, session_id, payload}` -- the same dispatch seam
  # `:interrupt`/`:steer` use. The runtime consumer replies to the parked
  # ACP `session/request_permission` with the chosen `option_id` and
  # journals the durable `approval_decided` event the harness folds into
  # the block; the payload always carries `option_id` (the referent the
  # operator chose), plus `request_id`/`decision` when present.
  def route(%__MODULE__{type: :approval_decision, payload: payload}, session) do
    dispatch(session, {:approval_decision, session_id(session), payload})
  end

  def route(%__MODULE__{type: :attach, payload: payload}, session) do
    reattach(session, payload)
  end

  def route(%__MODULE__{type: :seek, payload: %{offset: offset}}, session) do
    seek(session, offset)
  end

  # AD-15 seek: time-travel the read-model to a journal offset — fold the
  # durable events with id <= offset into the block projection. Read-side and
  # pure: reads via the tolerant Reader (writerless-safe), decodes with the
  # wire-safe `EventCodec` (unknown types stay strings, no atom minted from
  # disk), folds with `Raxol.Harness.Projection`. Returns `{:ok, projection}` or
  # `{:error, :damaged}`.
  defp seek(session, offset) do
    case FileStore.read_records(session_id(session)) do
      {:ok, records} ->
        projection =
          records
          |> Enum.filter(fn %{"id" => id} -> id <= offset end)
          |> EventCodec.decode_all()
          |> Projection.project()

        {:ok, projection}

      {:error, :damaged} = err ->
        err
    end
  end

  # AD-15 attach: subscribe `session.pid` to the durable stream and replay from
  # an offset. `:replay` streams durable records id >= from_offset (then live);
  # `:live` streams only records above the decision-time high-watermark;
  # `:snapshot` needs U9 snapshot restore and is not yet supported. Delivery is
  # `{:reattach_live, session_id, record}` to the subscriber (the session pid, or
  # the calling process when the session carries none).
  defp reattach(session, %{from_offset: from_offset, history_policy: :replay}) do
    attach_from(session, from_offset)
  end

  defp reattach(session, %{history_policy: :live}) do
    attach_from(session, FileStore.high_watermark(session_id(session)) + 1)
  end

  defp reattach(_session, %{history_policy: policy}) do
    {:error, {:unsupported_history_policy, policy}}
  end

  defp attach_from(session, from_offset) do
    Reattach.attach(session_id(session), from_offset, :none, subscriber: subscriber(session))
  end

  defp subscriber(session), do: session_pid(session) || self()

  # -- Decode internals -------------------------------------------------------

  defp fetch_type(map) do
    case get(map, "type", :type) do
      nil -> {:error, {:invalid_command, :missing_type}}
      type when is_binary(type) -> normalize_type(type)
      type when is_atom(type) -> normalize_type(Atom.to_string(type))
      _ -> {:error, {:invalid_command, :invalid_type}}
    end
  end

  defp normalize_type(str) do
    case Map.fetch(@types, str) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:invalid_command, {:unknown_type, str}}}
    end
  end

  # Payload is the nested "payload"/:payload map; absent → empty map. A
  # non-map payload is normalized to empty (validation then rejects on the
  # missing required field, with a field-specific reason).
  defp fetch_payload(map) do
    case get(map, "payload", :payload) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp validate(:prompt, payload) do
    case get(payload, "text", :text) do
      text when is_binary(text) ->
        if String.trim(text) == "" do
          {:error, {:invalid_command, :empty_text}}
        else
          {:ok, prompt_payload(text, payload)}
        end

      nil ->
        {:error, {:invalid_command, :missing_text}}

      _ ->
        {:error, {:invalid_command, :invalid_text}}
    end
  end

  defp validate(:interrupt, payload) do
    case get(payload, "turn_id", :turn_id) do
      nil -> {:ok, %{}}
      turn_id -> {:ok, %{turn_id: turn_id}}
    end
  end

  defp validate(:steer, payload) do
    with {:ok, text} <- fetch_steer_text(payload),
         {:ok, expected_turn_id} <- fetch_expected_turn_id(payload) do
      {:ok, steer_payload(text, expected_turn_id, payload)}
    end
  end

  # `option_id` is the REFERENT the operator chose (the concrete ACP
  # `PermissionOption`); it is required -- an answer with no option is not
  # an answer. `request_id` (correlation) and `decision` (an allow/deny
  # class hint) ride along when the surface supplied them.
  defp validate(:approval_decision, payload) do
    case get(payload, "option_id", :option_id) do
      option_id when is_binary(option_id) and option_id != "" ->
        {:ok, approval_decision_payload(option_id, payload)}

      nil ->
        {:error, {:invalid_command, :missing_option_id}}

      "" ->
        {:error, {:invalid_command, :empty_option_id}}

      _other ->
        {:error, {:invalid_command, :invalid_option_id}}
    end
  end

  defp validate(:attach, payload) do
    with {:ok, offset} <- fetch_offset(payload, "from_offset", :from_offset),
         {:ok, policy} <- fetch_history_policy(payload) do
      {:ok, %{from_offset: offset, history_policy: policy}}
    end
  end

  defp validate(:seek, payload) do
    with {:ok, offset} <- fetch_offset(payload, "offset", :offset) do
      {:ok, %{offset: offset}}
    end
  end

  defp prompt_payload(text, payload) do
    base = %{text: text}

    case get(payload, "attachments", :attachments) do
      list when is_list(list) -> Map.put(base, :attachments, list)
      _ -> base
    end
  end

  defp approval_decision_payload(option_id, payload) do
    %{option_id: option_id}
    |> put_if(:request_id, get(payload, "request_id", :request_id))
    |> put_if(:decision, get(payload, "decision", :decision))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # Reuses the exact rules/reasons `validate(:prompt, _)` uses for its own
  # required `text` field (:missing_text / :empty_text / :invalid_text) —
  # one vocabulary for "bad text payload", not two independently-drifting
  # ones.
  defp fetch_steer_text(payload) do
    case get(payload, "text", :text) do
      text when is_binary(text) ->
        if String.trim(text) == "" do
          {:error, {:invalid_command, :empty_text}}
        else
          {:ok, text}
        end

      nil ->
        {:error, {:invalid_command, :missing_text}}

      _other ->
        {:error, {:invalid_command, :invalid_text}}
    end
  end

  defp fetch_expected_turn_id(payload) do
    case get(payload, "expected_turn_id", :expected_turn_id) do
      nil -> {:error, {:invalid_command, :missing_expected_turn_id}}
      expected_turn_id -> {:ok, expected_turn_id}
    end
  end

  defp steer_payload(text, expected_turn_id, payload) do
    base = %{text: text, expected_turn_id: expected_turn_id}

    case get(payload, "client_msg_id", :client_msg_id) do
      nil -> base
      client_msg_id -> Map.put(base, :client_msg_id, client_msg_id)
    end
  end

  defp fetch_offset(payload, string_key, atom_key) do
    case get(payload, string_key, atom_key) do
      offset when is_integer(offset) and offset >= 0 ->
        {:ok, offset}

      nil ->
        {:error, {:invalid_command, {:missing_offset, atom_key}}}

      _ ->
        {:error, {:invalid_command, {:invalid_offset, atom_key}}}
    end
  end

  defp fetch_history_policy(payload) do
    case get(payload, "history_policy", :history_policy) do
      nil ->
        {:ok, :replay}

      policy when is_atom(policy) ->
        validate_history_policy(Atom.to_string(policy))

      policy when is_binary(policy) ->
        validate_history_policy(policy)

      _ ->
        {:error, {:invalid_command, :invalid_history_policy}}
    end
  end

  defp validate_history_policy(str) do
    case Map.fetch(@history_policies, str) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, {:invalid_command, {:unknown_history_policy, str}}}
    end
  end

  # Read a key that may be either the string or the atom form.
  defp get(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp decode_error_message(%Jason.DecodeError{} = error) do
    Exception.message(error)
  rescue
    _ -> "malformed JSON"
  end

  # -- Route internals --------------------------------------------------------

  defp dispatch(session, action) do
    case session_pid(session) do
      nil -> :ok
      pid -> send(pid, {:harness_command, action})
    end

    action
  end

  defp session_id(%{session_id: id}), do: id
  defp session_id(id) when is_binary(id), do: id
  defp session_id(_), do: nil

  defp session_pid(%{pid: pid}) when is_pid(pid), do: pid
  defp session_pid(_), do: nil
end
