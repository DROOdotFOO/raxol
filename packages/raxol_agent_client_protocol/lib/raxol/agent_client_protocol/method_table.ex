defmodule Raxol.AgentClientProtocol.MethodTable do
  @moduledoc """
  Single source of truth for the ACP method vocabulary: every wire method
  string, its direction, its JSON-RPC kind, the callback atom used for both
  the behaviour `@callback` and the `Router` dispatch clause, its
  param/result schema modules, its capability gate, and its layer.

  This binds to `priv/schema-oracle/v1/meta.json` (pinned at
  `schema-v1.19.0`), not to the f1729 reference implementation — f1729 has
  `session/fork`/`session/set_model` (not in the pinned oracle) and lacks
  `session/delete`/`session/close`/`logout`/`$/cancel_request` (which the
  oracle has). See `scratchpad/specs/acp-methodtable-design.md` for the
  full design, its G1 gate-review fix log (findings D1-1..D1-8), and the
  G2 `session/cancel` delta (§6.0) implemented below.

  ## What lives here vs. what doesn't (this task's scope)

  This module owns `rows/0`, `rows/1`, `rows_for_side/1`, and the
  compile-time table invariants (§1.1 of the design doc). Capability
  derivation/gating (design doc §6, artifact #3) and the `Connection`-side
  pre-filter for `layer: :protocol`/`:session_control` rows (§4's D1-2 fix,
  §6.0's G2 delta) are consumers of this table, not implemented here.

  ## Compile-time invariants (raise `CompileError` on violation)

  1. `{direction, wire}` is unique across all rows.
  2. `kind: :notification` implies `result == nil`; `kind: :request` implies
     `result != nil`.
  3. `callback` is unique per handling side (the set of callbacks visible to
     `rows_for_side(:agent)` has no duplicates, ignoring `nil`; ditto
     `:client`) — the anti-name-drift invariant.
  4. `layer in [:protocol, :session_control]` if and only if
     `callback == nil` (widened by the G2 `session/cancel` delta — see
     `scratchpad/specs/acp-methodtable-design.md` §6.0).
  5. `ext == nil` rows must not start with `"_"`; `ext == :raxol` rows must
     start with `"_raxol/"`; a `"$/"` wire prefix is only allowed on
     `layer: :protocol` rows.

  Invariant 6 from the design doc (every `params`/`result` module
  referenced must exist and export `from_json/1`) is checked in
  `test/method_table_test.exs` rather than at compile time, per the design
  doc's own rationale (avoiding compile-order knots between this module and
  the `Schema.*` modules it references).
  """

  alias Raxol.AgentClientProtocol.Schema.{AgentTypes, ClientTypes, LifecycleExtras, Unstable}

  @typedoc "Which side sends this row's wire method."
  @type direction :: :client_to_agent | :agent_to_client | :both

  @typedoc "JSON-RPC 2.0 shape: does this method get a reply?"
  @type kind :: :request | :notification

  @typedoc """
  `:app` — has an app-level `@callback` and `Router` dispatch clause.
  `:protocol` — protocol-level (`$/cancel_request`); `Connection` pre-filters
  before `Router.decode/4` is ever called (design doc §4 D1-2 fix).
  `:session_control` — app-shaped wire method, but Connection-routed with NO
  app callback (design doc §6.0 G2 delta; currently only `session/cancel`).
  """
  @type layer :: :app | :protocol | :session_control

  @typedoc "A path into the negotiated capability structs, or `nil` for baseline (always available)."
  @type capability :: nil | {:agent | :client, [atom()]}

  @typedoc "`nil` for the core v1.19.0 surface; `:raxol` for registered `_raxol/*` vendor rows."
  @type ext :: nil | :raxol

  @type row :: %{
          wire: String.t(),
          direction: direction(),
          kind: kind(),
          callback: atom() | nil,
          params: module() | nil,
          result: module() | nil,
          capability: capability(),
          layer: layer(),
          ext: ext()
        }

  # -- Agent methods (direction: client_to_agent) -- 13 rows, meta.json `agentMethods` --

  @agent_rows [
    %{
      wire: "initialize",
      direction: :client_to_agent,
      kind: :request,
      callback: :initialize,
      params: AgentTypes.InitializeRequest,
      result: AgentTypes.InitializeResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "authenticate",
      direction: :client_to_agent,
      kind: :request,
      callback: :authenticate,
      params: AgentTypes.AuthenticateRequest,
      result: AgentTypes.AuthenticateResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/new",
      direction: :client_to_agent,
      kind: :request,
      callback: :new_session,
      params: AgentTypes.NewSessionRequest,
      result: AgentTypes.NewSessionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/load",
      direction: :client_to_agent,
      kind: :request,
      callback: :load_session,
      params: AgentTypes.LoadSessionRequest,
      result: AgentTypes.LoadSessionResponse,
      capability: {:agent, [:load_session]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/set_mode",
      direction: :client_to_agent,
      kind: :request,
      callback: :set_session_mode,
      params: AgentTypes.SetSessionModeRequest,
      result: AgentTypes.SetSessionModeResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/set_config_option",
      direction: :client_to_agent,
      kind: :request,
      callback: :set_session_config_option,
      params: Unstable.SetSessionConfigOptionRequest,
      result: Unstable.SetSessionConfigOptionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/prompt",
      direction: :client_to_agent,
      kind: :request,
      callback: :prompt,
      params: AgentTypes.PromptRequest,
      result: AgentTypes.PromptResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      # G2 delta (design doc §6.0): session-control, Connection-routed, no
      # app callback — same treatment as $/cancel_request, keyed by session
      # id instead of request id. See invariant 4.
      wire: "session/cancel",
      direction: :client_to_agent,
      kind: :notification,
      callback: nil,
      params: AgentTypes.CancelNotification,
      result: nil,
      capability: nil,
      layer: :session_control,
      ext: nil
    },
    %{
      wire: "session/list",
      direction: :client_to_agent,
      kind: :request,
      callback: :list_sessions,
      params: Unstable.ListSessionsRequest,
      result: Unstable.ListSessionsResponse,
      capability: {:agent, [:sessions, :list]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/delete",
      direction: :client_to_agent,
      kind: :request,
      callback: :delete_session,
      params: LifecycleExtras.DeleteSessionRequest,
      result: LifecycleExtras.DeleteSessionResponse,
      capability: {:agent, [:sessions, :delete]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/resume",
      direction: :client_to_agent,
      kind: :request,
      callback: :resume_session,
      params: Unstable.ResumeSessionRequest,
      result: Unstable.ResumeSessionResponse,
      capability: {:agent, [:sessions, :resume]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/close",
      direction: :client_to_agent,
      kind: :request,
      callback: :close_session,
      params: LifecycleExtras.CloseSessionRequest,
      result: LifecycleExtras.CloseSessionResponse,
      capability: {:agent, [:sessions, :close]},
      layer: :app,
      ext: nil
    },
    %{
      # D1-6: params: nil — logout's request body carries nothing besides
      # the universal _meta envelope (schema.json LogoutRequest has no other
      # properties). decode passes nil straight through; the generated
      # callback drops to arity 1 (ctx only). See LifecycleExtras moduledoc
      # for why there is no LogoutRequest struct.
      wire: "logout",
      direction: :client_to_agent,
      kind: :request,
      callback: :logout,
      params: nil,
      result: LifecycleExtras.LogoutResponse,
      capability: {:agent, [:logout]},
      layer: :app,
      ext: nil
    }
  ]

  # -- Client methods (direction: agent_to_client) -- 9 rows, meta.json `clientMethods` --

  @client_rows [
    %{
      wire: "session/request_permission",
      direction: :agent_to_client,
      kind: :request,
      callback: :request_permission,
      params: ClientTypes.RequestPermissionRequest,
      result: ClientTypes.RequestPermissionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/update",
      direction: :agent_to_client,
      kind: :notification,
      callback: :session_update,
      params: LifecycleExtras.SessionNotification,
      result: nil,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "fs/write_text_file",
      direction: :agent_to_client,
      kind: :request,
      callback: :write_text_file,
      params: ClientTypes.WriteTextFileRequest,
      result: ClientTypes.WriteTextFileResponse,
      capability: {:client, [:fs, :write_text_file]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "fs/read_text_file",
      direction: :agent_to_client,
      kind: :request,
      callback: :read_text_file,
      params: ClientTypes.ReadTextFileRequest,
      result: ClientTypes.ReadTextFileResponse,
      capability: {:client, [:fs, :read_text_file]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/create",
      direction: :agent_to_client,
      kind: :request,
      callback: :create_terminal,
      params: ClientTypes.CreateTerminalRequest,
      result: ClientTypes.CreateTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/output",
      direction: :agent_to_client,
      kind: :request,
      callback: :terminal_output,
      params: ClientTypes.TerminalOutputRequest,
      result: ClientTypes.TerminalOutputResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/release",
      direction: :agent_to_client,
      kind: :request,
      callback: :release_terminal,
      params: ClientTypes.ReleaseTerminalRequest,
      result: ClientTypes.ReleaseTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/wait_for_exit",
      direction: :agent_to_client,
      kind: :request,
      callback: :wait_for_terminal_exit,
      params: ClientTypes.WaitForTerminalExitRequest,
      result: ClientTypes.WaitForTerminalExitResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/kill",
      direction: :agent_to_client,
      kind: :request,
      callback: :kill_terminal,
      params: ClientTypes.KillTerminalRequest,
      result: ClientTypes.KillTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    }
  ]

  # -- Protocol methods (direction: both) -- 1 row, meta.json `protocolMethods` --

  @protocol_rows [
    %{
      # D1-2: Connection pre-filters this wire method before Router.decode/4
      # is ever called; no Router clause is generated for it (see §4).
      wire: "$/cancel_request",
      direction: :both,
      kind: :notification,
      callback: nil,
      params: LifecycleExtras.CancelRequestNotification,
      result: nil,
      capability: nil,
      layer: :protocol,
      ext: nil
    }
  ]

  @rows @agent_rows ++ @client_rows ++ @protocol_rows

  # -- Compile-time invariants -------------------------------------------------

  duplicate_direction_wire =
    @rows
    |> Enum.frequencies_by(&{&1.direction, &1.wire})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))

  if duplicate_direction_wire != [] do
    raise CompileError,
      description:
        "MethodTable invariant 1 violated: duplicate {direction, wire} rows: " <>
          inspect(duplicate_direction_wire)
  end

  bad_result_arity =
    Enum.filter(@rows, fn
      %{kind: :notification, result: result} -> result != nil
      %{kind: :request, result: result} -> result == nil
    end)

  if bad_result_arity != [] do
    raise CompileError,
      description:
        "MethodTable invariant 2 violated (notification must have result: nil, " <>
          "request must have result != nil): " <>
          inspect(Enum.map(bad_result_arity, & &1.wire))
  end

  agent_handling_rows = Enum.filter(@rows, &(&1.direction in [:client_to_agent, :both]))
  client_handling_rows = Enum.filter(@rows, &(&1.direction in [:agent_to_client, :both]))

  duplicate_callbacks = fn side_rows ->
    side_rows
    |> Enum.map(& &1.callback)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_cb, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  dup_agent_callbacks = duplicate_callbacks.(agent_handling_rows)
  dup_client_callbacks = duplicate_callbacks.(client_handling_rows)

  if dup_agent_callbacks != [] or dup_client_callbacks != [] do
    raise CompileError,
      description:
        "MethodTable invariant 3 violated (duplicate callback atom per handling side): " <>
          "agent=#{inspect(dup_agent_callbacks)} client=#{inspect(dup_client_callbacks)}"
  end

  bad_layer_callback =
    Enum.filter(@rows, fn row ->
      case row.layer do
        layer when layer in [:protocol, :session_control] -> row.callback != nil
        :app -> row.callback == nil
      end
    end)

  if bad_layer_callback != [] do
    raise CompileError,
      description:
        "MethodTable invariant 4 violated (layer in [:protocol, :session_control] " <>
          "<=> callback == nil): " <> inspect(Enum.map(bad_layer_callback, & &1.wire))
  end

  bad_core_ext_prefix =
    Enum.filter(@rows, fn row -> row.ext == nil and String.starts_with?(row.wire, "_") end)

  bad_raxol_ext_prefix =
    Enum.filter(@rows, fn row ->
      row.ext == :raxol and not String.starts_with?(row.wire, "_raxol/")
    end)

  bad_protocol_prefix =
    Enum.filter(@rows, fn row ->
      String.starts_with?(row.wire, "$/") and row.layer != :protocol
    end)

  if bad_core_ext_prefix != [] or bad_raxol_ext_prefix != [] or bad_protocol_prefix != [] do
    raise CompileError,
      description:
        "MethodTable invariant 5 violated: " <>
          "core-with-underscore=#{inspect(Enum.map(bad_core_ext_prefix, & &1.wire))} " <>
          "raxol-without-prefix=#{inspect(Enum.map(bad_raxol_ext_prefix, & &1.wire))} " <>
          "dollar-outside-protocol=#{inspect(Enum.map(bad_protocol_prefix, & &1.wire))}"
  end

  # -- Public API ---------------------------------------------------------------

  @doc "All table rows, in declaration order (agent methods, then client methods, then protocol methods)."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc "Rows whose `direction` matches exactly."
  @spec rows(direction()) :: [row()]
  def rows(direction) when direction in [:client_to_agent, :agent_to_client, :both] do
    Enum.filter(@rows, &(&1.direction == direction))
  end

  @doc """
  Rows a given handling side must be able to decode/dispatch: `:agent` sees
  everything sent `:client_to_agent` plus `:both`; `:client` sees everything
  sent `:agent_to_client` plus `:both` (design doc §2.1, D1-7 fix).
  """
  @spec rows_for_side(:agent | :client) :: [row()]
  def rows_for_side(:agent), do: rows(:client_to_agent) ++ rows(:both)
  def rows_for_side(:client), do: rows(:agent_to_client) ++ rows(:both)
end
