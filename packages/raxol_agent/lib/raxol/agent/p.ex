defmodule Raxol.Agent.P do
  @moduledoc """
  The headless one-shot agent run -- the `raxol -p` surface, as a plain
  function.

  Shared by every entrypoint: `mix raxol.p` (dev), the `raxol p` subcommand
  of the Burrito-packaged CLI (release), and the repo-root `bin/raxol -p`
  wrapper. Contains no Mix calls, so it runs inside a release where Mix does
  not exist; `run/1` returns the exit code and leaves halting to the caller.

  Contract (see `Mix.Tasks.Raxol.P` for the full doc):

    * stdout -- the answer only
    * stderr -- one JSON contract event per line
    * exit 0 success, 1 run error, 2 timeout or budget exhausted,
      64 usage error, 143 terminated (SIGTERM)
    * `RAXOL_*` env contract via `Raxol.Agent.BenchmarkProfile`;
      trajectory written on every exit path when configured
  """

  alias Raxol.Agent.BenchmarkProfile
  alias Raxol.Agent.Contract
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.SignalTrap
  alias Raxol.Agent.Trajectory

  @default_timeout_s 180

  @switches [
    backend: :string,
    # `--harness` is a deprecated alias for `--backend`.
    harness: :string,
    model: :string,
    base_url: :string,
    system: :string,
    timeout: :integer,
    write: :boolean,
    tools: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @usage """
  Usage: raxol p [options] "prompt"    (dev: mix raxol.p [options] "prompt")

  One-shot headless agent run: answer to stdout, one JSON contract event
  per line to stderr.

  Options:
    --backend NAME   LLM backend (auto-detected if omitted; --harness is a
                     deprecated alias; e.g. --backend lm_studio for a local
                     server)
    --model NAME     model override
    --base-url URL   override the backend base URL
    --system TEXT    system prompt override
    --timeout SECS   per-run timeout in seconds (default 180)
    --write          expose write_file/edit_file/bash (opt-in; unattended)
    --no-tools       plain completion, no tool loop
    -h, --help       print this help

  Exit codes: 0 success, 1 run error, 2 timeout or budget exhausted,
  64 usage error, 143 terminated (SIGTERM)
  Full docs: mix help raxol.p
  """

  @doc "Run one headless turn from `argv`; returns the process exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    prompt = Enum.join(args, " ") |> String.trim()

    cond do
      Keyword.get(opts, :help, false) ->
        IO.puts(@usage)
        0

      invalid != [] ->
        usage_error!("unknown options: #{inspect(invalid)}")

      prompt == "" ->
        usage_error!("no prompt given")

      true ->
        run_prompt(prompt, opts)
    end
  catch
    {:raxol_p_usage, message} ->
      IO.puts(:stderr, "raxol-p: #{message}\n\n#{@usage}")
      64

    {:raxol_p_config, message} ->
      IO.puts(:stderr, "raxol-p: #{message}")
      1
  end

  # Non-local exit for the deep parse/validate sites; caught in run/1.
  defp usage_error!(message), do: throw({:raxol_p_usage, message})

  # A configuration problem (no provider, no credential), not a usage
  # problem: exit 1. Thrown before the run starts, so no JSONL event stream
  # exists yet and a plain stderr line cannot corrupt it.
  defp config_error!(message), do: throw({:raxol_p_config, message})

  defp run_prompt(prompt, opts) do
    # Resolve the profile and the provider before booting anything: a
    # machine with no provider configured gets an actionable error and
    # exit 1, not a connection refusal against a placeholder endpoint
    # mid-run. CLI flags win over the env profile; the profile wins over
    # auto-detection.
    profile =
      case BenchmarkProfile.from_env() do
        {:ok, profile} -> profile
        {:error, message} -> usage_error!(message)
      end

    opts = apply_profile_defaults(opts, profile)

    # Privilege escalation must never be invisible: RAXOL_PROFILE=benchmark
    # arms allow-all tools (including bash) from ambient env alone, so the
    # very first stderr line states it -- an event log that never mentions
    # the profile was a run that never had it.
    if profile.active? do
      IO.puts(
        :stderr,
        ~s({"type":"benchmark_profile","payload":{"authorizer":"allow_all","write_tools":true,"skills":"off"}})
      )
    end

    # stderr is reserved for the JSONL event stream, so pass prog: nil to
    # suppress the plain-text deprecation notice that would corrupt it.
    executor =
      case Raxol.Agent.Backend.Cli.resolve_executor(opts, nil) do
        {:ok, executor, _source} -> executor
        {:error, message} -> config_error!(message)
      end

    # Agent environment only -- no terminal driver, no UI. stdout belongs to
    # the answer; keep Logger quiet below :error. Under `mix raxol.p` the
    # task has already booted the app; in the release the boot did. The
    # ensure_all_started is the idempotent belt for any other caller.
    System.put_env("RAXOL_SKIP_TERMINAL_INIT", "true")
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:raxol_agent)

    # Claim SIGTERM unconditionally: the BEAM default turns it into a clean
    # exit 0, which a harness reads as success. We flush and exit 143. A
    # failed install degrades to the BEAM default -- say so rather than
    # silently losing the signal contract.
    case SignalTrap.install(self()) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          ~s({"type":"error","payload":{"reason":"signal_trap_unavailable","detail":#{inspect(inspect(reason))}}})
        )
    end

    ensure_streamer!()

    session_id = "cli-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    stream_opts = build_stream_opts(prompt, opts, profile, executor)
    use_tools = Keyword.get(opts, :tools, true)

    # The runner task and the streamer are linked to this process. Without
    # trapping, a bug-class raise inside the pump would kill us through the
    # link -- in the release that crashes Application.start (ugly boot
    # failure, no trajectory). Trapped, it arrives as an EXIT message and
    # the consume loop turns it into a flushed exit 1.
    Process.flag(:trap_exit, true)

    runner =
      Task.async(fn ->
        stream =
          if use_tools do
            Raxol.Agent.Stream.react(prompt, stream_opts)
          else
            Raxol.Agent.Stream.run(prompt, stream_opts)
          end

        Contract.pump(session_id, stream, prompt: prompt)
      end)

    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_s) * 1_000

    state = %{
      wrote_stdout: false,
      profile: profile,
      prompt: prompt,
      backend: executor.backend,
      turns: 0,
      usage: %{input_tokens: 0, output_tokens: 0},
      events: if(profile.trajectory_path, do: [], else: nil)
    }

    consume(session_id, runner, timeout_ms, state)
  end

  # SessionStreamer is not in any package supervision tree yet (the CLI is
  # its first live consumer); start it idempotently.
  defp ensure_streamer! do
    case SessionStreamer.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "cannot start SessionStreamer: #{inspect(reason)}"
    end
  end

  defp build_stream_opts(_prompt, opts, profile, executor) do
    backend_opts =
      []
      |> maybe_put(:base_url, Keyword.get(opts, :base_url))

    system =
      Keyword.get(
        opts,
        :system,
        "You are a helpful assistant running in a terminal at the user's " <>
          "current working directory. Use the available tools to inspect " <>
          "files when the question is about them. Be concise."
      )

    write? = Keyword.get(opts, :write, false)

    [
      executor: executor,
      backend_opts: backend_opts,
      system_prompt: system,
      actions: actions_for(write?, profile)
    ] ++ context_for(write?, profile)
  end

  defp apply_profile_defaults(opts, %BenchmarkProfile{} = profile) do
    opts
    |> maybe_default(
      :backend,
      profile.backend && Atom.to_string(profile.backend)
    )
    |> maybe_default(:model, profile.model)
  end

  defp maybe_default(opts, _key, nil), do: opts

  defp maybe_default(opts, key, value) do
    if Keyword.has_key?(opts, key),
      do: opts,
      else: Keyword.put(opts, key, value)
  end

  # Read-only by default (fs read tools + grep/glob). `--write` adds the
  # mutating coding tools (write_file/edit_file/bash), which are `sensitive`
  # and denied under the default policy -- so it also installs an allow-all
  # authorizer to actually let them run in this unattended headless flow.
  #
  # The benchmark profile forces write-mode semantics (no human to ask; the
  # task container is the blast radius) and drops skills entirely: task
  # attempts must be independent, so no cross-run skill loop.
  defp actions_for(_write?, %BenchmarkProfile{active?: true}),
    do: Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.all()

  defp actions_for(false, _profile),
    do:
      Raxol.Agent.Actions.Fs.all() ++
        Raxol.Agent.Actions.Code.read_only() ++
        Raxol.Agent.Skills.enabled_actions()

  defp actions_for(true, _profile),
    do:
      Raxol.Agent.Actions.Fs.all() ++
        Raxol.Agent.Actions.Code.all() ++
        Raxol.Agent.Skills.enabled_actions()

  defp context_for(_write?, %BenchmarkProfile{active?: true}),
    do: [context: %{tool_authorizer: Raxol.Agent.ToolPolicy.allow_all()}]

  defp context_for(false, _profile), do: maybe_skills_context(%{})

  defp context_for(true, _profile),
    do:
      maybe_skills_context(%{
        tool_authorizer: Raxol.Agent.ToolPolicy.allow_all()
      })

  # Add the configured skills store under context[:skills]; keep the
  # empty-context `[]` shape when nothing (skills or authorizer) needs to be
  # passed.
  defp maybe_skills_context(base) do
    base =
      case Raxol.Agent.Skills.default_context() do
        nil -> base
        skills -> Map.put(base, :skills, skills)
      end

    if map_size(base) == 0, do: [], else: [context: base]
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # -- Event consumption: contract events in, stdout/stderr out --------------

  defp consume(session_id, runner, timeout_ms, state) do
    receive do
      {:session_event, ^session_id, %Contract.Event{} = event} ->
        IO.write(:stderr, Contract.encode_line(event))

        state =
          event
          |> render_stdout(state)
          |> track(event)

        case event do
          %{type: :turn_completed, payload: %{final: true}} ->
            Task.await(runner, 5_000)
            if state.wrote_stdout, do: IO.write("\n")
            finish(state, 0, :completed)

          %{type: :error} ->
            Task.await(runner, 5_000)
            finish(state, 1, :error)

          _ ->
            check_budget_then_continue(session_id, runner, timeout_ms, state)
        end

      {:os_signal, :sigterm} ->
        IO.puts(
          :stderr,
          ~s({"type":"error","payload":{"reason":"terminated"}})
        )

        Task.shutdown(runner, :brutal_kill)
        finish(state, 143, :terminated)

      # Linked-process exits (we trap): normal task completion is noise;
      # anything else -- pump crash, streamer death -- ends the run as a
      # flushed error instead of killing this process through the link.
      {:EXIT, _pid, :normal} ->
        consume(session_id, runner, timeout_ms, state)

      {:EXIT, _pid, reason} ->
        IO.puts(
          :stderr,
          ~s({"type":"error","payload":{"reason":"crashed","detail":#{inspect(inspect(reason))}}})
        )

        Task.shutdown(runner, :brutal_kill)
        finish(state, 1, :error)
    after
      timeout_ms ->
        IO.puts(:stderr, ~s({"type":"error","payload":{"reason":"timeout"}}))
        Task.shutdown(runner, :brutal_kill)
        finish(state, 2, :timeout)
    end
  end

  defp check_budget_then_continue(session_id, runner, timeout_ms, state) do
    case BenchmarkProfile.budget_status(
           state.profile,
           state.turns,
           state.usage
         ) do
      :ok ->
        consume(session_id, runner, timeout_ms, state)

      {:exceeded, cap} ->
        IO.puts(
          :stderr,
          ~s({"type":"error","payload":{"reason":"budget_exhausted","cap":"#{cap}"}})
        )

        Task.shutdown(runner, :brutal_kill)
        finish(state, 2, :budget_exhausted)
    end
  end

  # Accumulate turn/usage totals and (when a trajectory is requested) the
  # event list itself.
  defp track(state, %{type: :turn_completed, payload: payload} = event) do
    state
    |> Map.update!(:turns, &(&1 + 1))
    |> Map.update!(
      :usage,
      &BenchmarkProfile.add_usage(&1, Map.get(payload, :usage, %{}))
    )
    |> record(event)
  end

  defp track(state, event), do: record(state, event)

  defp record(%{events: nil} = state, _event), do: state
  defp record(state, event), do: Map.update!(state, :events, &[event | &1])

  # Every exit path flushes the trajectory (when configured) and returns the
  # exit code.
  defp finish(state, exit_code, reason) do
    case state.profile.trajectory_path do
      nil ->
        :ok

      path ->
        trajectory =
          Trajectory.build(Enum.reverse(state.events || []), %{
            prompt: state.prompt,
            backend: state.backend,
            model: state.profile.model,
            profile: state.profile,
            turns: state.turns,
            usage: state.usage,
            exit_code: exit_code,
            reason: reason
          })

        Trajectory.write(path, trajectory)
    end

    exit_code
  end

  # stdout carries the ANSWER only. Stream deltas as they arrive; if the
  # run produced no deltas (non-streaming react loop), print the final
  # message content once.
  defp render_stdout(%{type: :item_delta, payload: %{chunk: chunk}}, state) do
    IO.write(chunk)
    %{state | wrote_stdout: true}
  end

  defp render_stdout(
         %{
           type: :item_completed,
           payload: %{item_type: :message, content: content}
         },
         %{wrote_stdout: false} = state
       ) do
    IO.write(content)
    %{state | wrote_stdout: true}
  end

  defp render_stdout(_event, state), do: state
end
