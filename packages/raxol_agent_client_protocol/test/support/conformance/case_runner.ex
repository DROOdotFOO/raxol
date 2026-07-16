defmodule Raxol.AgentClientProtocol.Test.Conformance.CaseRunner do
  @moduledoc """
  Native Elixir runner for the acpx (openclaw/acpx, MIT) v1 conformance
  corpus -- so CI needs no Node/pnpm to validate protocol compliance.

  ## Provenance

  `test/conformance/cases/*.json` (21 files) are copied verbatim from
  [`openclaw/acpx`](https://github.com/openclaw/acpx)'s
  `conformance/cases/*.json` (MIT License, Copyright (c) 2025 OpenClaw
  Team) -- see `NOTICE.md`. This module ports the step/check *engine* of
  that repo's own reference runner (`conformance/runner/run.ts`, same MIT
  license) from TypeScript to Elixir: same step vocabulary (`new_session`,
  `prompt`, `prompt_background`, `await_background`, `cancel`, `sleep`),
  same check vocabulary (`initialize_protocol_version_number`,
  `saved_non_empty_string`, `saved_error_present`, `saved_stop_reason_in`,
  `updates_count_at_least`, `updates_all_session`, `updates_text_includes`,
  `updates_session_update_includes`), same `$saved_key` back-reference
  syntax, same default timeouts (10s request / 30s update) -- but drives
  `Raxol.AgentClientProtocol.Agent`/`Client` over
  `Raxol.AgentClientProtocol.Transport.Paired` in-process instead of
  spawning a Node child process and talking `@agentclientprotocol/sdk`
  NDJSON-over-stdio to it. No `expect_error` step in a copied case uses the
  upstream `${saved.X}` template form (only bare `$key`), so that form is
  not ported.

  The agent/client under test are the fixtures in this same `test/support/`
  tree: `Raxol.AgentClientProtocol.Test.Conformance.MockAgent` (a small
  text-command DSL ported from upstream's own `test/mock-agent.ts` fixture,
  to the extent the 21 copied cases exercise it) and `.MockClient` (ported
  from `run.ts`'s own `RunnerClient`). Every case gets its own fresh
  `Agent`/`Client` connection pair and its own scratch cwd (with a
  `README.md` fixture file, for the two cases that `read` it), exactly
  mirroring the upstream runner spawning a fresh agent process per case.

  ## Compliance notes (found while porting, not fixed here -- out of this
  coder's assigned files)

    * `Schema.AgentTypes.NewSessionRequest.from_json/1` (and, by the same
      `AgentTypes.fetch/2` pattern, several sibling `from_json/1`s across
      `agent_types.ex`) fetches a field's *presence* but never checks its
      *type* against the oracle schema -- `cwd: 12345` and `cwd: null`
      both decode successfully as `%NewSessionRequest{cwd: 12345 | nil}`
      instead of failing at `Router.decode/4` with `-32602` the way a
      schema-validating peer (the upstream TS SDK's own Zod-validated
      `AgentSideConnection`, which is what actually rejects
      `acp.v1.errors.invalid_params` / `.invalid_params.cwd_null` upstream
      -- the *reference* `mock-agent.ts`'s own `newSession` handler doesn't
      inspect `cwd` at all) would. `MockAgent.new_session/2` compensates
      with its own `is_binary/1` guard so these two cases still exercise a
      real, machine-readable `-32602` from *this* package's stack -- but
      the schema layer's own leniency here is worth another coder's look;
      it likely affects other typed string fields the same way (see
      `acp.v1.errors.invalid_prompt_session_type`, which happens to still
      pass because a non-string `session_id` simply fails this fixture's
      own session-registry lookup instead, landing on the *same*
      `-32603 Unknown session` path used for a truly-unknown id).

    * `acp.v1.session.prompt.post_success_drain` assumes an agent that
      violates protocol ordering (emits `session/update` notifications
      *after* the terminal `session/prompt` response for that turn) --
      this package's `Session` enforces that ordering as a real invariant
      (I3, the "straggler-task guard", `session.ex` §3.3): a `post_update/2`
      once the turn has closed is dropped, not delivered. `MockAgent`
      reproduces the same *observable update set* the case checks for via
      `Session.spawn_task/2` (the turn-group hold-open primitive) instead
      of the upstream fixture's bare `setTimeout`-after-reply, so the case
      still passes -- but this is a deliberate deviation from what the
      corpus's own reference agent does, worth a second opinion on whether
      I3 is too strict for real-world "fire tool telemetry after replying"
      agent patterns. See `MockAgent.do_late_tool/3`'s doc for the full
      reasoning.

  No case in this 21-file profile exercises `session/fork`, `session/list`,
  `session/resume`, `session/set_model`, or `$/cancel_request` (the acpx v1
  spec's own "out of scope for v1" list, `conformance/spec/v1.md`) or
  `session/load` -- so none needed a `:pending` disposition; all 21 run for
  real against this package's own agent/client stack.
  """

  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Transport

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    CancelNotification,
    InitializeRequest,
    NewSessionRequest,
    PromptRequest
  }

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{ClientCapabilities, FileSystemCapability}
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Test.Conformance.MockAgent
  alias Raxol.AgentClientProtocol.Test.Conformance.MockClient

  @default_request_timeout_ms 10_000
  @default_update_timeout_ms 30_000
  @initialize_timeout_ms 10_000

  @type outcome :: :pass | {:fail, String.t()}

  @doc "Load and JSON-decode one case fixture file."
  @spec load_case(Path.t()) :: map()
  def load_case(path), do: path |> File.read!() |> Jason.decode!()

  @doc """
  Run one decoded case: fresh Agent/Client connection pair, fresh scratch
  cwd, every `steps` entry executed in order, every `checks` entry
  evaluated after (plus `settle_timeout_ms`, if the case declares one).
  Always tears the connection pair and scratch dir down, pass or fail.
  """
  @spec run(map()) :: outcome()
  def run(case_def) when is_map(case_def) do
    permission_mode = normalize_permission_mode(case_def["permission_mode"])
    cwd = make_scratch_cwd!()

    opts = %{
      cwd: cwd,
      request_timeout_ms: timeout_of(case_def, "request_timeout_ms", @default_request_timeout_ms),
      update_timeout_ms: timeout_of(case_def, "update_timeout_ms", @default_update_timeout_ms)
    }

    # `start_harness/1` `start_link`s two supervisors, LINKING them to
    # whichever process calls `run/1` (an ExUnit test process, which does
    # NOT trap exits by default). `force_stop/1`'s `Supervisor.stop/3` can
    # legitimately propagate a non-`:normal` EXIT while a live `Session`
    # child (or the Connection's own `terminate/2` draining pending tasks)
    # is torn down under a tight timeout budget -- trapping here for the
    # duration of the run turns that into an inert mailbox message instead
    # of silently killing the calling test process. Restored, and any
    # accumulated `{:EXIT, _, _}` noise drained, before returning so it
    # never leaks into the caller's own `receive`/`assert_receive` calls.
    prev_trap = Process.flag(:trap_exit, true)

    result =
      case start_harness(permission_mode) do
        {:ok, harness} ->
          try do
            run_case_body(case_def, harness, opts)
          rescue
            e -> {:fail, Exception.format(:error, e, __STACKTRACE__)}
          catch
            {:conformance_fail, reason} -> {:fail, reason}
          after
            stop_harness(harness)
          end

        {:error, reason} ->
          {:fail, "harness setup failed: #{inspect(reason)}"}
      end

    drain_exits()
    Process.flag(:trap_exit, prev_trap)
    File.rm_rf(cwd)
    result
  end

  defp drain_exits do
    receive do
      {:EXIT, _pid, _reason} -> drain_exits()
    after
      0 -> :ok
    end
  end

  defp run_case_body(case_def, harness, opts) do
    ctx = %{saved: %{}, background: %{}}
    ctx = run_steps(case_def["steps"] || [], harness, opts, ctx)

    settle_ms = timeout_of(case_def, "settle_timeout_ms", 0)
    if settle_ms > 0, do: Process.sleep(settle_ms)

    run_checks(case_def["checks"] || [], harness, ctx)
    :pass
  end

  defp timeout_of(case_def, key, default) do
    case get_in(case_def, ["timeouts", key]) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp normalize_permission_mode("deny-all"), do: :deny_all
  defp normalize_permission_mode(_other), do: :approve_all

  # ===========================================================================
  # Harness lifecycle
  # ===========================================================================

  defp start_harness(permission_mode) do
    {agent_handle, client_handle} = Transport.Paired.create_pair()
    client_state = MockClient.new_state(permission_mode)

    {:ok, agent_sup} = AcpAgent.start_link(MockAgent, transport: {Transport.Paired, agent_handle})

    {:ok, client_sup} =
      AcpClient.start_link(MockClient,
        transport: {Transport.Paired, client_handle},
        handler_arg: client_state
      )

    client_conn = connection_pid(client_sup)

    caps = %ClientCapabilities{
      file_system: %FileSystemCapability{read_text_file: true, write_text_file: true}
    }

    init_req = %{InitializeRequest.new(1) | client_capabilities: caps}

    case Connection.request(client_conn, "initialize", init_req, @initialize_timeout_ms) do
      {:ok, init_resp} ->
        {:ok,
         %{
           agent_sup: agent_sup,
           client_sup: client_sup,
           client_conn: client_conn,
           client_state: client_state,
           init_resp: init_resp
         }}

      {:error, reason} ->
        force_stop(agent_sup)
        force_stop(client_sup)
        {:error, {:initialize_failed, reason}}
    end
  end

  defp stop_harness(harness) do
    force_stop(harness.agent_sup)
    force_stop(harness.client_sup)
    if Process.alive?(harness.client_state), do: Elixir.Agent.stop(harness.client_state)
  end

  defp force_stop(sup) do
    Supervisor.stop(sup, :normal, 500)
  catch
    :exit, _reason -> :ok
  end

  defp connection_pid(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Raxol.AgentClientProtocol.Connection, pid, _type, _mods} -> pid
      _other -> nil
    end)
  end

  defp make_scratch_cwd! do
    dir = Path.join(System.tmp_dir!(), "acp_conformance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "README.md"),
      "# acpx conformance fixture\n\nBacks the raxol ACP conformance corpus (ported from acpx, MIT).\n"
    )

    dir
  end

  # ===========================================================================
  # Steps
  # ===========================================================================

  defp run_steps(steps, harness, opts, ctx) do
    Enum.reduce(steps, ctx, fn step, ctx -> run_step(step, harness, opts, ctx) end)
  end

  defp run_step(%{"action" => "sleep", "ms" => ms}, _harness, _opts, ctx) do
    Process.sleep(round(ms))
    ctx
  end

  defp run_step(%{"action" => "new_session"} = step, harness, opts, ctx) do
    cwd_value = if Map.has_key?(step, "cwd"), do: step["cwd"], else: opts.cwd
    req = NewSessionRequest.new(cwd_value)
    result = Connection.request(harness.client_conn, "session/new", req, opts.request_timeout_ms)
    result = apply_expect_error(result, step["expect_error"], "session/new")

    # Mirrors the upstream runner's own `new_session` save shape exactly
    # (run.ts): on success, save the bare session id string (not the whole
    # response struct) whenever one decoded; only fall back to the raw
    # response/error otherwise.
    saved_value =
      case result do
        {:ok, %{session_id: session_id}} when is_binary(session_id) ->
          MockClient.register_session_cwd(harness.client_state, session_id, cwd_value)
          session_id

        {:ok, value} ->
          value

        {:error, value} ->
          value
      end

    save(ctx, step["save_as"], saved_value)
  end

  defp run_step(%{"action" => "prompt"} = step, harness, opts, ctx) do
    session_id = resolve_ref(step["session"], ctx.saved)
    blocks = Enum.map(step["prompt"], &decode_prompt_block!/1)
    req = PromptRequest.new(session_id, blocks)

    result =
      Connection.request(harness.client_conn, "session/prompt", req, opts.update_timeout_ms)

    result = apply_expect_error(result, step["expect_error"], "session/prompt")
    save(ctx, step["save_as"], unwrap(result))
  end

  defp run_step(%{"action" => "prompt_background"} = step, harness, opts, ctx) do
    session_id = resolve_ref(step["session"], ctx.saved)
    blocks = Enum.map(step["prompt"], &decode_prompt_block!/1)
    req = PromptRequest.new(session_id, blocks)

    task =
      Task.async(fn ->
        Connection.request(harness.client_conn, "session/prompt", req, opts.update_timeout_ms)
      end)

    %{ctx | background: Map.put(ctx.background, step["save_as"], task)}
  end

  defp run_step(%{"action" => "await_background"} = step, _harness, opts, ctx) do
    task =
      Map.get(ctx.background, step["from"]) ||
        throw({:conformance_fail, "unknown background prompt reference: #{step["from"]}"})

    result = Task.await(task, opts.update_timeout_ms + 2_000)
    result = apply_expect_error(result, step["expect_error"], "await_background:#{step["from"]}")
    save(ctx, step["save_as"], unwrap(result))
  end

  defp run_step(%{"action" => "cancel"} = step, harness, _opts, ctx) do
    session_id = resolve_ref(step["session"], ctx.saved)

    :ok =
      Connection.notify(harness.client_conn, "session/cancel", CancelNotification.new(session_id))

    ctx
  end

  defp decode_prompt_block!(block_json) do
    case ContentBlock.from_json(block_json) do
      {:ok, block} ->
        block

      {:error, reason} ->
        throw({:conformance_fail, "bad prompt block fixture: #{inspect(reason)}"})
    end
  end

  # -- expect_error / save / $ref plumbing -------------------------------------

  defp apply_expect_error({:ok, _value} = ok, nil, _label), do: ok

  defp apply_expect_error({:ok, value}, expect, label) when not is_nil(expect) do
    throw(
      {:conformance_fail, "#{label} succeeded but error was expected (got #{inspect(value)})"}
    )
  end

  defp apply_expect_error({:error, reason} = err, nil, label) do
    if is_nil(reason) do
      err
    else
      throw({:conformance_fail, "#{label} failed unexpectedly: #{inspect(reason)}"})
    end
  end

  defp apply_expect_error({:error, error} = err, expect, _label) when not is_nil(expect) do
    validate_expected_error(error, expect)
    err
  end

  defp validate_expected_error(error, expect) do
    code = error_code(error)
    message = error_message_blob(error)
    lower_message = String.downcase(message)

    codes = expect["codes"] || []

    if codes != [] and code not in codes do
      throw(
        {:conformance_fail,
         "unexpected error code #{inspect(code)}; expected one of #{inspect(codes)} (message: #{message})"}
      )
    end

    fragments = expect["message_any"] || []

    if fragments != [] and
         not Enum.any?(fragments, &String.contains?(lower_message, String.downcase(&1))) do
      throw(
        {:conformance_fail,
         "unexpected error message #{inspect(message)}; expected one of #{inspect(fragments)}"}
      )
    end

    :ok
  end

  defp error_code(%Raxol.AgentClientProtocol.Error{code: code}), do: code
  defp error_code(_other), do: nil

  defp error_message_blob(%Raxol.AgentClientProtocol.Error{message: message, data: data}) do
    if data, do: "#{message} #{inspect(data)}", else: message
  end

  defp error_message_blob(other), do: inspect(other)

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, value}), do: value

  defp save(ctx, nil, _value), do: ctx
  defp save(ctx, key, value), do: %{ctx | saved: Map.put(ctx.saved, key, value)}

  defp resolve_ref("$" <> key, saved) do
    case Map.fetch(saved, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        throw(
          {:conformance_fail,
           "saved reference \"#{key}\" is not a non-empty string: #{inspect(other)}"}
        )

      :error ->
        throw({:conformance_fail, "unknown saved reference: $#{key}"})
    end
  end

  defp resolve_ref(value, _saved), do: value

  # ===========================================================================
  # Checks
  # ===========================================================================

  defp run_checks(checks, harness, ctx) do
    Enum.each(checks, &run_check(&1, harness, ctx))
  end

  defp run_check(%{"type" => "initialize_protocol_version_number"}, harness, _ctx) do
    unless is_integer(harness.init_resp.protocol_version) do
      throw(
        {:conformance_fail,
         "initialize response protocolVersion is not a number: #{inspect(harness.init_resp.protocol_version)}"}
      )
    end
  end

  defp run_check(%{"type" => "saved_non_empty_string", "key" => key}, _harness, ctx) do
    case Map.get(ctx.saved, key) do
      value when is_binary(value) and value != "" ->
        :ok

      other ->
        throw(
          {:conformance_fail, "saved.#{key} must be a non-empty string, got #{inspect(other)}"}
        )
    end
  end

  defp run_check(%{"type" => "saved_error_present", "key" => key}, _harness, ctx) do
    case Map.get(ctx.saved, key) do
      nil -> throw({:conformance_fail, "saved.#{key} must be present"})
      _other -> :ok
    end
  end

  defp run_check(
         %{"type" => "saved_stop_reason_in", "key" => key, "values" => values},
         _harness,
         ctx
       ) do
    case Map.get(ctx.saved, key) do
      %{stop_reason: reason} ->
        unless to_string(reason) in values do
          throw(
            {:conformance_fail,
             "saved.#{key}.stopReason (#{inspect(reason)}) must be in #{inspect(values)}"}
          )
        end

      other ->
        throw(
          {:conformance_fail,
           "saved.#{key} must be present with a stop reason, got #{inspect(other)}"}
        )
    end
  end

  defp run_check(%{"type" => "updates_count_at_least", "min" => min}, harness, _ctx) do
    count = harness.client_state |> MockClient.updates() |> length()

    unless count >= min do
      throw({:conformance_fail, "expected at least #{min} updates, got #{count}"})
    end
  end

  defp run_check(%{"type" => "updates_all_session", "session" => session_ref}, harness, ctx) do
    session_id = resolve_ref(session_ref, ctx.saved)
    updates = MockClient.updates(harness.client_state)
    bad = Enum.reject(updates, &(&1.session_id == session_id))

    unless bad == [] do
      throw(
        {:conformance_fail,
         "#{length(bad)} update(s) not for session #{inspect(session_id)}: #{inspect(bad)}"}
      )
    end
  end

  defp run_check(%{"type" => "updates_text_includes", "text" => text}, harness, _ctx) do
    needle = String.downcase(text)
    updates = MockClient.updates(harness.client_state)

    unless Enum.any?(updates, &update_text_includes?(&1, needle)) do
      throw({:conformance_fail, "expected at least one update text including #{inspect(text)}"})
    end
  end

  defp run_check(
         %{"type" => "updates_session_update_includes", "values" => values},
         harness,
         _ctx
       ) do
    updates = MockClient.updates(harness.client_state)
    seen = updates |> Enum.map(&update_tag/1) |> MapSet.new()
    missing = Enum.reject(values, &(&1 in seen))

    unless missing == [] do
      throw(
        {:conformance_fail,
         "missing sessionUpdate variant(s) #{inspect(missing)} (seen: #{inspect(MapSet.to_list(seen))})"}
      )
    end
  end

  defp update_text_includes?(%{update: {tag, %{content: {:text, %{text: text}}}}}, needle)
       when tag in [:user_message_chunk, :agent_message_chunk, :agent_thought_chunk] do
    String.contains?(String.downcase(text), needle)
  end

  defp update_text_includes?(_other, _needle), do: false

  defp update_tag(%{update: {tag, _payload}}), do: Atom.to_string(tag)
end
