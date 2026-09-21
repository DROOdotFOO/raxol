defmodule Raxol.Agent.Code.App.Commands do
  @moduledoc """
  Slash-command surface for `Raxol.Agent.Code.App`.

  `dispatch_slash/2` parses a `/command arg` line and routes it to one body per
  command. Three shapes come back, by role, so the TEA contract is unchanged:

    * `dispatch_slash/2` returns `{model, commands}`, the `App.update/2` shape.
    * `connect/4`, `switch_session/2`, `apply_signin/3`, and the
      `apply_*_result/2` folds return the bare model (some with a `_ref` set,
      because they armed an async fetch whose `{:command_result, ...}` message
      lands in `App.update/2` too).
    * `validation_status/2`, `interpret_ping/1`, `auth_rejected?/1`, and
      `normalize_share_secret/1` are pure helpers on plain values.

  Adding a command means one `apply_command/3` clause plus its body here, and
  one `help_text/0` line -- not four edits spread across the state machine. A
  command that needs a key binding still adds one `App.update/2` clause,
  because the keyboard belongs to the shell.

  The async commands (`/resume`, `/sessions`, `/model`, `/inspect`, `/login`)
  each ship an injectable default fetcher (`default_sessions_fetcher/3` and
  friends) that runs off the app process; `App.config/2` wires them, and tests
  replace them. Everything that ARMS a fetch captures `self()` as the reply
  address, so this module must run in the App process (see the `App`
  moduledoc for the helper contract it calls back into).
  """

  require Logger

  alias Raxol.Agent.Authorization.Engine
  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Code.App.Wizard
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.Block

  # The wall bound on every async fetch: the UI must get an answer, so this
  # deliberately preempts a backend's own longer socket timeout, and
  # `models_fetch_opts/1` threads it into the HTTP opts so the inner timeout
  # is not dead configuration that can never fire. Sized above `/inspect`'s
  # own worst case (`Resolver.op_status/0` is documented at "under 7s", plus
  # one 1.5s reference read), because a snapshot is most useful precisely
  # when the vault is locked and slow.
  @fetch_timeout_ms 20_000

  # `/login`'s validation ping is a single-token completion, not a fetch: it
  # has its own, tighter budget so that changing the fetch bound cannot
  # silently change a credential check's socket timeout.
  @ping_timeout_ms 10_000

  # -- dispatch ---------------------------------------------------------------

  @doc false
  def dispatch_slash(model, command) do
    {name, arg} = parse_command(command)
    apply_command(name, arg, model)
  end

  defp apply_command("help", _arg, model), do: {App.notice(model, help_text()), []}

  # In a jailed (multi-tenant) session the keyboard principal is a tenant, not
  # the host owner. /login and /logout mutate the HOST-GLOBAL credential store
  # (`Credentials.put`/`delete`, one file for the whole node), so a tenant must
  # not reach them: the host pre-wires the provider via server app_opts.
  defp apply_command(cmd, _arg, %{jail: true} = model)
       when cmd in ["login", "logout"] do
    {refuse_hosted_credentials(model), []}
  end

  defp apply_command("login", arg, model), do: {login(model, arg), []}
  defp apply_command("clear", _arg, model), do: {clear_session(model), []}

  defp apply_command("plan", _arg, model),
    do: {App.maybe_toggle_plan_mode(model), []}

  defp apply_command("model", arg, model), do: {set_model(model, arg), []}

  defp apply_command("context", _arg, model),
    do: {App.notice(model, context_text(model)), []}

  defp apply_command("usage", _arg, model),
    do: {App.notice(model, usage_text(model)), []}

  defp apply_command("compact", _arg, model), do: {compact(model), []}

  defp apply_command("rewind", _arg, model), do: {rewind(model), []}

  defp apply_command("rename", arg, model),
    do: {rename(model, String.trim(arg)), []}

  defp apply_command("resume", arg, model) do
    case String.trim(arg) do
      "" -> {open_session_picker(model), []}
      key -> {switch_session(model, key), []}
    end
  end

  defp apply_command("fork", arg, model),
    do: {fork_session(model, String.trim(arg)), []}

  defp apply_command("export", arg, model),
    do: {export_session(model, String.trim(arg)), []}

  defp apply_command("transcript", _arg, model),
    do: {write_transcript(model), []}

  # /copy drives the HOST clipboard — unavailable to a jailed tenant.
  defp apply_command("copy", _arg, %{jail: true} = model),
    do: {App.notice(model, "clipboard is unavailable in a hosted session"), []}

  defp apply_command("copy", _arg, model), do: {copy_last_answer(model), []}

  defp apply_command("find", arg, model),
    do: {find_in_transcript(model, String.trim(arg)), []}

  defp apply_command("logout", arg, model),
    do: {logout(model, String.trim(arg)), []}

  defp apply_command("share", _arg, model), do: {share_session(model), []}

  # Listing reads (and fully decodes) every session file, so it runs off
  # the app process like the /resume picker — one fetcher, two modes.
  defp apply_command("sessions", _arg, model),
    do: {arm_sessions_fetch(model, :list), []}

  defp apply_command("mcp", _arg, model),
    do: {App.notice(model, mcp_text(model)), []}

  defp apply_command("hooks", _arg, model),
    do: {App.notice(model, hooks_text(model)), []}

  # `/inspect` renders the host's provider topology (`Resolver.diagnostics/0`
  # reports per-provider `source`, whether an `op://` reference is stored,
  # and whether the vault is unlocked), the host's skills and session roots,
  # and which language servers are installed -- and gathering it performs a
  # real 1Password read, so a tenant keystroke can raise an authorization
  # prompt on the operator's own machine. That is host state, not session
  # state: a jailed tenant is refused here for the same reason `/login` is,
  # rather than being shown the credential topology item 6 just stopped
  # advertising on the same screen.
  defp apply_command("inspect", _arg, %{jail: true} = model),
    do: {App.notice(model, "inspection is disabled in a hosted session"), []}

  defp apply_command("inspect", _arg, %{inspection_ref: ref} = model)
       when is_reference(ref),
       do: {App.put_status(model, "already inspecting…"), []}

  defp apply_command("inspect", _arg, model) do
    ref = make_ref()
    model.inspection_fetcher.(model.cwd, model.sessions_dir, ref, self())
    {%{model | inspection_ref: ref} |> App.put_status("inspecting…"), []}
  end

  defp apply_command(other, _arg, model),
    do: {App.notice(model, "unknown command: /#{other} — try /help"), []}

  defp parse_command("/" <> rest) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [name] -> {name, ""}
      [name, arg] -> {name, String.trim(arg)}
    end
  end

  defp help_text do
    """
    /help              this help
    /login [provider]  connect an LLM provider (op ref, key, or local)
    /clear             start a fresh session
    /model [name]      switch model (no name = pick from the provider's list)
    /plan              toggle plan mode
    /compact           shrink the conversation history
    /rewind            drop the last turn (transcript + conversation)
    /context           session stats
    /usage             session token and cost totals
    /sessions          list saved sessions
    /resume [id]       switch session (no id = pick from a list)
    /fork [title]      branch a copy of this session and continue there
    /rename <title>    title this session (shown in /sessions)
    /export [path]     write the transcript to a file (default: cwd)
    /transcript        write the transcript to a temp file for paging
    /copy              copy the last reply to the clipboard
    /find <text>       search the transcript blocks
    /logout [provider] disconnect (with a name: forget its credential)
    /share             mint a read-only share link for this session
    /mcp               list configured MCP servers
    /hooks             show configured lifecycle hooks
    /inspect           show every config source in use (providers, pin, hooks, MCP, skills, sessions)
    """
    |> String.trim_trailing()
  end

  # -- /help /mcp /hooks /inspect ---------------------------------------------

  @doc false
  # The one notice every host-global credential gate answers with: the
  # /login and /logout commands, `connect/4`, and the wizard's 1Password save.
  def refuse_hosted_credentials(model),
    do: App.notice(model, "credential management is disabled in a hosted session")

  @doc false
  # Default fetcher: gather + render the snapshot off the app process (a
  # fresh disk read, the same snapshot `mix raxol.inspect` prints); the
  # result rides back as an `:inspection_result` message `App.update/2` folds.
  # The spawned process is unlinked; `app` must be the App process.
  def default_inspection_fetcher(cwd, sessions_dir, ref, app) do
    fetch_async(app, :inspection_result, ref, fn ->
      cwd
      |> Raxol.Agent.Code.Inspection.gather(sessions_dir: sessions_dir)
      |> Raxol.Agent.Code.Inspection.render()
    end)
  end

  @doc false
  def apply_inspection_result(model, {:error, reason}) do
    %{model | inspection_ref: nil, status_line: nil}
    |> App.notice("inspection failed: #{fetch_failure(reason)}")
  end

  # `Inspection.render/1` returns a binary, but the fetcher is an injectable
  # seam: an iolist is what a `render/1` refactor naturally produces, and
  # the view tolerated one long before this fold existed, so converting is
  # cheaper than a `FunctionClauseError` inside `App.update/2`.
  def apply_inspection_result(model, text) when is_binary(text) or is_list(text),
    do: App.notice(%{model | inspection_ref: nil, status_line: nil}, text)

  @doc false
  # The one shape every default fetcher runs through: `work` executes off
  # the App process and its value rides back as `{:command_result, {tag, ref,
  # value}}`. A raise, exit, or throw inside `work` becomes `{:error,
  # {:crashed, class}}` and an overrun becomes `{:error, :timeout}`, so the
  # message always arrives and the fold clears the `_ref` that armed it.
  #
  # The reporter TRAPS EXITS, and that is load-bearing rather than
  # decorative: `Task.async/1` links as well as monitors, so a task death the
  # inner `try` cannot intercept -- a `max_heap_size` kill, an external
  # `Process.exit(task, :kill)`, an exit signal arriving through a link the
  # work function itself created (an HTTP client's pool helper, say) -- would
  # otherwise kill this process through that link BEFORE `Task.yield/2`
  # returns. No message would be sent, the `*_ref` would stay armed and the
  # status line would stay wedged for the life of the session, which is the
  # exact bug this function exists to remove. Trapping turns that signal into
  # the `{:exit, reason}` `Task.yield/2` reports.
  #
  # The spawned process is unlinked from the App; `app` must be the App
  # process.
  def fetch_async(app, tag, ref, work, timeout \\ @fetch_timeout_ms) do
    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(app, {:command_result, {tag, ref, bounded(tag, work, timeout)}})
    end)
  end

  defp bounded(tag, work, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, work.()}
        rescue
          error -> {:error, {:crashed, error.__struct__}, describe(:error, error)}
        catch
          kind, reason -> {:error, {:crashed, kind}, describe(kind, reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, value}} ->
        value

      {:ok, {:error, class, detail}} ->
        Logger.warning("#{tag} fetch crashed: #{detail}")
        {:error, class}

      {:exit, reason} ->
        Logger.warning("#{tag} fetch exited: #{describe_exit(reason)}")
        {:error, {:crashed, :exit}}

      nil ->
        Logger.warning("#{tag} fetch timed out after #{timeout}ms")
        {:error, :timeout}
    end
  end

  # Banner and location only, never the stacktrace's ARGUMENTS. A VM-raised
  # error (`function_clause`, `undef`, `badarg`) carries the call's arguments
  # in its top frame, and `Exception.format/3` renders them with `inspect/1`
  # -- for the models fetcher those arguments are the backend opts, which
  # hold `:api_key`. Logging the formatted exception put the provider key in
  # the host log (CWE-532).
  defp describe(kind, reason), do: Exception.format_banner(kind, reason)

  defp describe_exit({reason, _stacktrace}) when is_tuple(reason) or is_atom(reason),
    do: inspect(reason, limit: 3)

  defp describe_exit(reason), do: inspect(reason, limit: 3)

  defp fetch_failure(:timeout), do: "timed out"
  defp fetch_failure({:crashed, :exit}), do: "the worker exited"
  defp fetch_failure({:crashed, class}), do: "crashed (#{inspect(class)})"

  # Every other `{:error, reason}` a fetcher's own work function can return
  # (`File.read/1`'s `:enoent`, an HTTP client's own error term). Without
  # this clause the folds -- which accept ANY `{:error, reason}` -- crashed
  # the App process on a shape `bounded/3` never mints but `work` can return
  # straight through, reintroducing the wedge class from the other side.
  defp fetch_failure(other), do: "failed (#{inspect(other, limit: 3)})"

  # A jailed session reads no `.mcp.json` at all, so "none configured" would
  # misdescribe it: the file may well be there, and the operator should know
  # it was refused rather than go looking for a config bug.
  defp mcp_text(%{mcp_servers: [], jail: true}),
    do: "MCP servers are disabled in a jailed session"

  defp mcp_text(%{mcp_servers: []} = model) do
    case skipped_rows(model) do
      [] -> "no MCP servers configured (.mcp.json)"
      rows -> Enum.join(rows, "\n")
    end
  end

  defp mcp_text(%{mcp_servers: servers} = model) do
    rows =
      Enum.map(servers, fn s ->
        "#{server_mark(model.mcp_status, s.name)} #{s.name}  →  #{target_text(s)}" <>
          failure_text(model.mcp_status, s.name)
      end)

    Enum.join(rows ++ skipped_rows(model), "\n")
  end

  # What the entry declares, which is what the operator has to fix when it
  # does not start: a command line, a URL, or neither. Reading `:command`
  # unconditionally raised on a remote server, which carries no such key.
  defp target_text(%{command: command} = server) when is_binary(command) do
    String.trim("#{command} #{Enum.join(Map.get(server, :args, []), " ")}")
  end

  defp target_text(%{url: url}) when is_binary(url), do: url
  defp target_text(_server), do: "(no command or url)"

  # `✗` is a server that started and failed, so it carries its reason here
  # rather than being a mark with no explanation next to a `⊘` row that has
  # one. An entry the bridge refused after starting -- a host the operator
  # never allowlisted, a handshake refusal -- comes back through the same
  # `failed` list; one the loader never tried at all rides in `mcp_skipped`.
  defp failure_text(%{failed: failed}, name) do
    case Enum.find(failed, fn {n, _reason} -> to_string(n) == name end) do
      nil -> ""
      {_n, reason} -> "  (failed: #{inspect(reason, limit: 3)})"
    end
  end

  defp failure_text(_status, _name), do: ""

  # Entries `.mcp.json` names that the bridge never started, with the reason,
  # so the operator sees them here rather than hunting for a config bug.
  # `⊘` is "never tried", distinct from `✗` ("tried and failed"). Bounded by
  # the cap the loader bounds launches with: a file with 10k broken entries
  # is otherwise a 10k-row notice, re-rendered every frame.
  defp skipped_rows(model) do
    {shown, rest} =
      Enum.split(model.mcp_skipped, Raxol.Agent.Code.McpLoader.max_servers())

    rows =
      Enum.map(shown, fn {name, reason} ->
        "⊘ #{name}  →  skipped: #{skip_text(reason)}"
      end)

    case rest do
      [] -> rows
      more -> rows ++ ["  … and #{length(more)} more skipped"]
    end
  end

  defp skip_text(:unsupported_transport),
    do: "type is http/sse but the entry names no url"

  defp skip_text(:no_command), do: "entry names neither a command nor a url"
  defp skip_text(:command_not_string), do: "command is not a string"
  defp skip_text(:not_an_object), do: "entry is not an object"
  defp server_mark(:loading, _name), do: "…"
  defp server_mark(nil, _name), do: "○"

  defp server_mark(%{connected: connected, failed: failed}, name) do
    atom = String.to_existing_atom(name)

    cond do
      atom in connected -> "●"
      Enum.any?(failed, fn {n, _reason} -> n == atom end) -> "✗"
      true -> "○"
    end
  rescue
    ArgumentError -> "○"
  end

  defp hooks_text(%{hooks: nil}), do: "no hooks configured (.raxol/hooks.json)"

  defp hooks_text(%{hooks: config}) do
    "pre_tool_use: #{length(config.pre)} · post_tool_use: #{length(config.post)} · " <>
      "stop: #{length(config.stop)}"
  end

  # -- /login: connect a provider ---------------------------------------------

  # `/login`                         -> status + usage
  # `/login <provider>`              -> connect via op/env (or keyless local)
  # `/login <provider> op://ref`     -> store the 1Password reference + connect
  # `/login <provider> <key>`        -> session-only key (never persisted)
  # a trailing token is taken as a model override.
  defp login(model, arg) do
    case String.split(String.trim(arg), ~r/\s+/, trim: true) do
      [] ->
        Wizard.open_browse(model)

      [provider] ->
        login_provider(model, provider, nil, nil)

      # Spelled out rather than inferred: `/login <provider>` already means
      # "resolve from op/env", and a browser opening on its own would be a
      # surprise.
      [provider, "browser"] ->
        login_browser(model, provider)

      [provider, secret] ->
        login_provider(model, provider, secret, nil)

      [provider, secret, model_name | _] ->
        login_provider(model, provider, secret, model_name)
    end
  end

  defp login_browser(model, provider_str) do
    case Raxol.Agent.Backend.Resolver.harness_from_string(provider_str) do
      {:ok, harness} ->
        start_browser_signin(model, harness)

      :error ->
        App.notice(
          model,
          "unknown provider: #{provider_str}\n\n" <> Wizard.login_status_text()
        )
    end
  end

  defp start_browser_signin(model, harness) do
    if Raxol.Agent.Auth.Flow.supported?(harness) do
      ref = make_ref()
      model.signin_runner.(harness, ref, self())

      %{model | signin_ref: ref}
      |> App.notice("opening a browser to sign in to #{harness}...")
      |> App.put_status("waiting for #{harness} sign-in...")
    else
      App.notice(
        model,
        "#{harness} has no browser sign-in. Connect it with an api key or an " <>
          "op:// reference:\n  /login #{harness} <api-key>"
      )
    end
  end

  @doc false
  def apply_signin(model, harness, {:ok, _result}) do
    resolve_and_connect(model, harness, [], "browser sign-in")
  end

  def apply_signin(model, harness, {:error, reason}) do
    App.notice(
      model,
      "#{harness} sign-in failed: #{Raxol.Agent.Auth.Flow.describe(reason)}"
    )
  end

  defp login_provider(model, provider_str, secret, model_name) do
    case Raxol.Agent.Backend.Resolver.harness_from_string(provider_str) do
      {:ok, harness} ->
        connect(model, harness, secret, model_name)

      :error ->
        App.notice(
          model,
          "unknown provider: #{provider_str}\n\n" <> Wizard.login_status_text()
        )
    end
  end

  @doc false
  # An op:// reference is stored (so it survives relaunch) then resolved; a raw
  # key stays in memory for this session only; no secret connects via op/env.
  #
  # The op:// path writes the HOST-GLOBAL credential store, and every path
  # arms a validation ping addressed to `self()`. A jailed tenant is refused
  # here, at the resource, so no caller (the /login text path, the wizard) can
  # reach the store around the command gate.
  def connect(%{jail: true} = model, _harness, _secret, _model_name),
    do: refuse_hosted_credentials(model)

  def connect(model, harness, "op://" <> _ = ref, model_name) do
    case Raxol.Agent.Backend.Credentials.put(
           harness,
           put_model([op_ref: ref], model_name)
         ) do
      :ok ->
        resolve_and_connect(model, harness, [], "op reference stored")

      {:error, reason} ->
        App.notice(model, "could not store reference: #{inspect(reason)}")
    end
  end

  def connect(model, harness, secret, model_name) when is_binary(secret) do
    resolve_and_connect(
      model,
      harness,
      put_model([api_key: secret], model_name),
      "session key — not persisted"
    )
  end

  def connect(model, harness, nil, model_name) do
    resolve_and_connect(model, harness, put_model([], model_name), nil)
  end

  defp resolve_and_connect(model, harness, extra_opts, note) do
    opts = Keyword.put(extra_opts, :harness, harness)

    case Raxol.Agent.Backend.Resolver.resolve(opts) do
      {:ok, executor, source} ->
        # Fire a cheap, async validation ping; its result arrives as a
        # `{:login_validation, ...}` message and updates the status line. The
        # connection is marked ready immediately either way — validation only
        # annotates it, so a slow or offline check never blocks the TUI.
        ref = start_login_validation(model, executor)

        %{
          model
          | executor: executor,
            provider_status: {:ready, harness, source},
            model_override: executor.model || model.model_override,
            login_ref: ref,
            wizard: nil
        }
        |> App.notice(connect_note(harness, source, note))
        |> App.put_status("connected to #{harness} — validating credential…")

      {:no_key, ^harness} ->
        App.notice(
          model,
          "no credential found for #{harness}. Supply one:\n" <>
            "  /login #{harness} op://Vault/Item/field   (1Password)\n" <>
            "  /login #{harness} <api-key>               (this session only)"
        )

      :no_provider ->
        App.notice(model, "could not resolve a provider for #{harness}")
    end
  end

  defp put_model(opts, nil), do: opts
  defp put_model(opts, ""), do: opts
  defp put_model(opts, model_name), do: Keyword.put(opts, :model, model_name)

  defp connect_note(harness, source, nil),
    do: "connected to #{harness} (via #{source})"

  defp connect_note(harness, source, note),
    do: "connected to #{harness} (via #{source}) — #{note}"

  @doc false
  # The default sign-in runner: the whole OAuth flow off the app process, so a
  # user who wanders off mid-approval cannot wedge the TUI. The outcome rides
  # back as a `:browser_signin` message, mirroring the validation ping. The
  # spawned process is unlinked; `app` must be the App process.
  def default_browser_signin(harness, ref, app) do
    spawn(fn ->
      result =
        try do
          Raxol.Agent.Auth.Flow.run(harness)
        rescue
          error -> {:error, error}
        catch
          _kind, reason -> {:error, reason}
        end

      send(app, {:command_result, {:browser_signin, ref, harness, result}})
    end)
  end

  @doc false
  # Kick off the injectable validator, returning the ref that stamps its
  # result. `self()` here is the app process, so the ping's reply message lands
  # where `App.update/2` can fold it -- calling this from any other process
  # loses the result.
  def start_login_validation(model, executor) do
    ref = make_ref()
    model.login_validator.(executor, ref, self())
    ref
  end

  @doc false
  # The default validator: a cheap, single-token completion against the freshly
  # resolved backend, off the app process so a hung endpoint never blocks the
  # TUI. The normalized outcome rides back as a `:login_validation` message.
  # The spawned process is unlinked; `app` must be the App process.
  def default_login_validator(executor, ref, app) do
    spawn(fn ->
      result =
        try do
          do_validate_ping(executor)
        rescue
          _ -> :unreachable
        catch
          _, _ -> :unreachable
        end

      send(
        app,
        {:command_result, {:login_validation, ref, executor.backend, result}}
      )
    end)

    :ok
  end

  defp do_validate_ping(executor) do
    case Raxol.Agent.Backend.Selector.select(executor) do
      {:ok, backend, opts} -> validate_backend(backend, opts)
      {:error, reason} -> {:select_error, reason}
    end
  end

  # Prefer the token-free model-list auth check for the HTTP backend; only an
  # ambiguous result (unsupported endpoint, or reachable-but-odd-status) falls
  # back to the authoritative single-token completion ping.
  defp validate_backend(Raxol.Agent.Backend.HTTP = backend, opts) do
    case Raxol.Agent.Backend.HTTP.check_auth(opts) do
      :unsupported -> ping_completion(backend, opts)
      {:reachable_error, _status} -> ping_completion(backend, opts)
      verdict -> verdict
    end
  end

  defp validate_backend(backend, opts), do: ping_completion(backend, opts)

  defp ping_completion(backend, opts) do
    ping_opts =
      opts |> Keyword.put(:max_tokens, 1) |> Keyword.put(:timeout, @ping_timeout_ms)

    interpret_ping(backend.complete([%{role: :user, content: "ping"}], ping_opts))
  end

  @doc false
  # Classify a backend `complete/2` return by what it says about the credential.
  # Auth is the question: a 401/403 rejects; a reachable endpoint that answered
  # (even a truncated/unparseable body) authorized the request, so it is valid.
  def interpret_ping({:ok, _response}), do: :valid

  def interpret_ping({:error, {:http_error, status, _body} = reason}) do
    if auth_rejected?(reason),
      do: {:rejected, status},
      else: {:reachable_error, status}
  end

  def interpret_ping({:error, {:request_failed, _reason}}), do: :unreachable
  def interpret_ping({:error, :req_not_available}), do: :req_unavailable
  def interpret_ping({:error, _marker}), do: :valid

  @doc false
  # Shared credential-rejection classifier for a backend error term — used by
  # both the `/login` ping (`interpret_ping/1`) and the mid-turn error fold
  # (`App.finalize_turn/2` on a contract `:error` event). Recognizes the
  # structured `complete/2` shape (`{:http_error, 401|403, _}`) and the
  # streaming shape (the "HTTP 401"/"HTTP 403" string `Backend.HTTP.stream/2`
  # surfaces as its error element).
  def auth_rejected?({:http_error, status, _body}) when status in [401, 403],
    do: true

  def auth_rejected?(reason) when is_binary(reason),
    do: reason =~ ~r/\bHTTP (401|403)\b/

  def auth_rejected?(_reason), do: false

  @doc false
  def validation_status(harness, :valid),
    do: "#{harness} credential validated ●"

  def validation_status(harness, {:rejected, status}),
    do: "#{harness} key rejected (HTTP #{status}) — check /login"

  def validation_status(harness, :unreachable),
    do: "#{harness} endpoint unreachable — is it running?"

  def validation_status(harness, {:reachable_error, status}),
    do: "#{harness} reachable but returned HTTP #{status}"

  def validation_status(harness, {:select_error, reason}),
    do: "#{harness} cannot validate: #{inspect(reason)}"

  def validation_status(harness, :req_unavailable),
    do: "#{harness} connected (Req unavailable, validation skipped)"

  def validation_status(harness, _other), do: "#{harness} connected"

  # -- /logout ----------------------------------------------------------------

  # `/logout` disconnects the session's provider (the setup panel
  # reopens); `/logout <provider>` additionally deletes that provider's
  # stored credential reference.
  defp logout(%{executor: nil} = model, ""),
    do: App.notice(model, "no provider connected")

  defp logout(model, "") do
    %{model | executor: nil, provider_status: :no_provider}
    |> Wizard.open_browse()
    |> App.notice("logged out — /login reconnects")
  end

  defp logout(model, provider) do
    case model.credential_remover.(provider) do
      {:ok, harness} ->
        # The remover is idempotent (it cannot tell whether a reference
        # was stored), and env-var keys are out of its reach entirely.
        model
        |> disconnect_if_current(harness)
        |> App.notice(
          "forgot stored credential for #{harness} " <>
            "(env keys, if any, persist until unset)"
        )

      {:error, reason} ->
        App.notice(model, "logout failed: #{inspect(reason)}")
    end
  end

  defp disconnect_if_current(%{executor: %{backend: harness}} = model, harness) do
    %{model | executor: nil, provider_status: :no_provider} |> Wizard.open_browse()
  end

  defp disconnect_if_current(model, _harness), do: model

  # -- /clear /rename ---------------------------------------------------------

  # A fresh session preserves the old file on disk and starts a new key, so
  # clearing is never destructive to a prior conversation. The old journal
  # closes (flushing its Writer); the new session lazily opens its own.
  # Approval grants and plan mode are per-session, so they reset too.
  defp clear_session(model) do
    App.close_journal(model.journal)

    %{
      model
      | messages: [],
        events: [],
        journal: nil,
        next_event_id: 1,
        dirty: false,
        turn_answer: "",
        face_state: :idle,
        face_frame: 0,
        session_key: App.mint_session_key(),
        title: "",
        parent: nil,
        plan_mode: false,
        always_allow: MapSet.new(),
        auth_state: Engine.new(),
        notice: "cleared — new session"
    }
  end

  # `/rename` titles the session; the title shows in `/sessions` and the
  # `/resume` picker, and persists with the session file.
  defp rename(model, ""), do: App.notice(model, "usage: /rename <title>")

  defp rename(model, title),
    do: %{model | title: title} |> App.persist() |> App.notice(~s(renamed to "#{title}"))

  # -- /rewind ----------------------------------------------------------------

  # Drops the last turn from the transcript and the conversation in
  # lockstep. The journal is append-only, so the drop is recorded there as
  # a meta `:rewind` marker — replay applies markers in offset order and
  # so converges with the live session; the JSON store just persists the
  # truncated state.
  defp rewind(%{running?: true} = model),
    do: App.notice(model, "cannot rewind while a turn is running")

  defp rewind(model) do
    cond do
      orphan_prompt?(model) ->
        # An aborted turn (Esc before its first event, or an eagerly
        # crashed worker) left the user prompt in the conversation but
        # no events; the trailing EVENTS belong to the previous turn.
        # Rewinding must undo the abort, not destroy the prior turn.
        [_orphan | rest] = Enum.reverse(model.messages)

        %{model | messages: Enum.reverse(rest)}
        |> App.persist()
        |> App.notice("rewound — removed the un-run prompt")

      model.events == [] ->
        App.notice(model, "nothing to rewind")

      true ->
        rewind_last_turn(model)
    end
  end

  defp rewind_last_turn(model) do
    {kept, dropped} = split_trailing_turn(model.events)
    turn_id = List.last(model.events).turn_id
    {messages, dropped_messages} = drop_turn_messages(model.messages)
    {model, marker_warning} = journal_rewind_marker(model, turn_id)

    model =
      App.persist(%{
        model
        | events: kept,
          next_event_id: next_id_after(kept),
          messages: messages,
          turn_answer: "",
          face_state: :idle
      })

    note =
      "rewound — dropped #{length(dropped)} events, " <>
        "#{dropped_messages} messages"

    App.notice(model, join_notes(note, marker_warning))
  end

  # Turn ids are only unique within one VM run (`Contract.pump` mints
  # them from `System.unique_integer`), so a session grown across
  # restarts can hold the same turn_id twice. Rewinding therefore drops
  # only the CONTIGUOUS trailing run of the last turn's events — never a
  # global match over the whole session — and the replay marker applies
  # the same trailing-run rule.
  defp split_trailing_turn([]), do: {[], []}

  defp split_trailing_turn(events) do
    turn_id = List.last(events).turn_id

    {dropped_rev, kept_rev} =
      events
      |> Enum.reverse()
      |> Enum.split_while(&(&1.turn_id == turn_id))

    {Enum.reverse(kept_rev), Enum.reverse(dropped_rev)}
  end

  defp next_id_after([]), do: 1
  defp next_id_after(kept), do: List.last(kept).id + 1

  # The abort signature: the conversation ends in a user prompt that no
  # event belongs to — the trailing events (if any) are a COMPLETED
  # turn, so the prompt was appended by a turn that never emitted.
  defp orphan_prompt?(model) do
    trailing_user? = match?([%{role: :user} | _], Enum.reverse(model.messages))

    completed_tail? =
      case List.last(model.events) do
        nil -> true
        %{type: :turn_completed} -> true
        _other -> false
      end

    trailing_user? and completed_tail?
  end

  defp join_notes(note, nil), do: note
  defp join_notes(note, warning), do: note <> " · " <> warning

  # The rewound turn's conversation tail is at most one user prompt plus
  # one assistant reply (an errored or interrupted turn appends no reply).
  defp drop_turn_messages(messages) do
    case Enum.reverse(messages) do
      [%{role: :assistant}, %{role: :user} | rest] ->
        {Enum.reverse(rest), 2}

      [%{role: :assistant} | rest] ->
        {Enum.reverse(rest), 1}

      [%{role: :user} | rest] ->
        {Enum.reverse(rest), 1}

      _other ->
        {messages, 0}
    end
  end

  defp journal_rewind_marker(model, turn_id) do
    record = %{
      v: 0,
      session_id: model.session_key,
      turn_id: nil,
      ts: System.system_time(:microsecond),
      family: :meta,
      type: :rewind,
      tier: :durable,
      payload: %{"dropped_turn" => turn_id}
    }

    case App.journal_append(model, record) do
      {model, nil} ->
        {model, nil}

      {model, _warning} ->
        {model, "journal marker failed — --replay may still show it"}
    end
  end

  # -- /resume /sessions /fork ------------------------------------------------

  defp open_session_picker(model), do: arm_sessions_fetch(model, :picker)

  # A fetch already in flight is not re-armed. Each arm mints a fresh ref
  # and the fold drops every older reply, so spamming `/sessions` used to
  # start N concurrent full-disk reads whose results were all discarded but
  # whose work was not -- trivial for a scripted or ACP client.
  defp arm_sessions_fetch(%{sessions_ref: ref} = model, _mode) when is_reference(ref),
    do: App.put_status(model, "already listing sessions…")

  defp arm_sessions_fetch(model, mode) do
    ref = make_ref()
    model.sessions_fetcher.(model.sessions_dir, ref, self())

    %{model | sessions_ref: ref, sessions_mode: mode}
    |> App.put_status("listing sessions…")
  end

  @doc false
  # Lists sessions off the app process (Store.list reads every session
  # file); the result rides back as a `:sessions_list` message. The spawned
  # process is unlinked; `app` must be the App process.
  def default_sessions_fetcher(dir, ref, app) do
    fetch_async(app, :sessions_list, ref, fn -> Raxol.Agent.Code.Store.list(dir) end)
  end

  @doc false
  def apply_sessions_result(model, {:error, reason}) do
    %{model | sessions_ref: nil, status_line: nil}
    |> App.notice("couldn't list sessions: #{fetch_failure(reason)}")
  end

  def apply_sessions_result(model, []) do
    %{model | sessions_ref: nil, status_line: nil}
    |> App.notice("no saved sessions")
  end

  def apply_sessions_result(%{sessions_mode: :list} = model, sessions) do
    text =
      sessions
      |> Enum.take(10)
      |> Enum.map_join("\n", &session_line/1)

    %{model | sessions_ref: nil, status_line: nil} |> App.notice(text)
  end

  def apply_sessions_result(model, sessions) do
    if Wizard.modal_wizard?(model) do
      # A modal step (masked credential entry) owns the screen; opening
      # the picker over it would discard half-typed secret input.
      %{model | sessions_ref: nil, status_line: nil}
    else
      entries =
        sessions
        |> Enum.take(20)
        |> Enum.map(&%{id: &1.id, label: session_line(&1)})

      cursor = Enum.find_index(entries, &(&1.id == model.session_key)) || 0

      %{
        model
        | sessions_ref: nil,
          status_line: nil,
          wizard: %{step: :sessions, entries: entries, cursor: cursor}
      }
    end
  end

  @doc false
  # Switching persists the departing session first (nothing is lost),
  # closes its journal, and rebuilds transcript + conversation from the
  # target — the in-place version of `--resume`.
  def switch_session(%{running?: true} = model, _key),
    do: App.notice(model, "cannot switch sessions while a turn is running")

  def switch_session(%{session_key: key} = model, key),
    do: App.notice(model, "already in session #{key}")

  # A session key is a FILENAME: it reaches Path.join unescaped in
  # /transcript and names the journal directory. Store.load only basenames it
  # for its own lookup, so a traversal would survive the load and land in the
  # model. Reject it here, where it enters, rather than at each use.
  def switch_session(model, key) do
    case Raxol.Agent.Code.ShareToken.valid_session_id?(key) do
      true -> enter_session(model, key)
      false -> App.notice(model, "not a session id: #{inspect(key)}")
    end
  end

  defp enter_session(model, key) do
    case Raxol.Agent.Code.Store.load(model.sessions_dir, key) do
      {:ok, saved} ->
        # Persist the departing session only when it holds unsaved
        # changes — a save always bumps updated_at, and merely peeking
        # at a session must not make it the --continue target.
        model = if model.dirty, do: App.persist(model), else: model
        App.close_journal(model.journal)
        events = App.renumber_events(saved.events)

        %{
          model
          | session_key: key,
            messages: saved.messages,
            events: events,
            next_event_id: length(events) + 1,
            dirty: false,
            journal: nil,
            title: saved.title,
            parent: saved.parent,
            turn_answer: "",
            face_state: :idle,
            # Approval grants and plan mode are per-session.
            plan_mode: false,
            always_allow: MapSet.new(),
            auth_state: Engine.new(),
            wizard: nil
        }
        |> App.notice("resumed #{key} (#{length(saved.messages)} messages)")

      {:error, :not_found} ->
        App.notice(model, "session #{key} not found — try /sessions")
    end
  end

  defp session_dirty?(model), do: model.messages != [] or model.events != []

  # Copy-fork: the conversation and transcript continue under a fresh key
  # whose store entry names its parent; the original session file stays
  # intact. The fork's journal starts fresh on its next durable event.
  defp fork_session(%{running?: true} = model, _title),
    do: App.notice(model, "cannot fork while a turn is running")

  defp fork_session(model, title) do
    if session_dirty?(model) do
      parent = model.session_key
      model = App.persist(model)
      App.close_journal(model.journal)
      new_key = App.mint_session_key()

      %{
        model
        | session_key: new_key,
          parent: parent,
          title: if(title == "", do: model.title, else: title),
          journal: nil
      }
      |> App.persist()
      |> App.notice("forked to #{new_key} (from #{parent})")
    else
      App.notice(model, "nothing to fork yet")
    end
  end

  defp session_line(session) do
    details =
      [
        title_note(session),
        "#{session.message_count} msgs",
        format_age(session.updated_at),
        shorten_home(session.cwd)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    "#{session.id}  (#{details})"
  end

  defp title_note(%{title: title}) when is_binary(title) and title != "",
    do: ~s("#{title}")

  defp title_note(_session), do: nil

  defp format_age(updated_at)
       when is_integer(updated_at) and updated_at > 0 do
    diff = System.system_time(:second) - updated_at

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp format_age(_updated_at), do: nil

  defp shorten_home(cwd) when is_binary(cwd) and cwd != "" do
    case System.user_home() do
      nil -> cwd
      home -> String.replace_prefix(cwd, home, "~")
    end
  end

  defp shorten_home(_cwd), do: nil

  # -- /export /transcript /copy /find ----------------------------------------

  # `/export [path]` writes the transcript as plain text; the default
  # lands beside the work as `<session_key>.txt` in the cwd. A jailed
  # session confines the destination to the workspace — same containment
  # decision the tools make.
  defp export_session(model, path_arg) do
    requested =
      case path_arg do
        "" -> "#{model.session_key}.txt"
        given -> given
      end

    case export_path(model, requested) do
      {:ok, path} ->
        write_transcript_file(model, path, &File.write/2, "exported to #{path}")

      {:error, :outside_cwd} ->
        App.notice(
          model,
          "export refused: the path escapes this session's workspace"
        )
    end
  end

  defp export_path(%{jail: true} = model, requested),
    do: Raxol.Agent.Actions.Fs.resolve(requested, %{cwd: model.cwd})

  defp export_path(model, requested),
    do: {:ok, Path.expand(requested, model.cwd)}

  # `/transcript` writes to a temp file and points a pager at it. The TUI
  # cannot suspend the terminal to host `$PAGER` itself (the driver owns
  # the tty), so the hint is the honest version. The file is created
  # exclusively with a fresh name and tightened to 0600 while still
  # empty: /tmp is shared on Linux, transcripts are conversations, and a
  # reused predictable path invites symlink games.
  defp write_transcript(model) do
    # A jailed session writes into its own workspace — the server's /tmp
    # is unreachable through jailed tools, so a path there would be
    # useless to the tenant.
    base = if model.jail == true, do: model.cwd, else: System.tmp_dir!()

    name =
      "#{model.session_key}-transcript-" <>
        "#{System.unique_integer([:positive])}.txt"

    case transcript_path(model, base, name) do
      {:ok, path} ->
        write_transcript_file(
          model,
          path,
          &write_private/2,
          "transcript written — view with: ${PAGER:-less} #{path}"
        )

      {:error, :outside_cwd} ->
        App.notice(model, "transcript refused: path escapes the workspace")
    end
  end

  # The filename embeds session_key, which both /resume and --resume take from
  # the user. They validate it on the way in; this is the check at the write
  # itself, so any future path into session_key cannot turn /transcript into a
  # file drop outside the jail. Mirrors what export_path/2 does for /export.
  defp transcript_path(%{jail: true} = model, base, name),
    do: Raxol.Agent.Actions.Fs.resolve(Path.join(base, name), %{cwd: model.cwd})

  defp transcript_path(_model, base, name), do: {:ok, Path.join(base, name)}

  defp write_transcript_file(model, path, writer, success_note) do
    text = Raxol.Agent.Code.Replay.transcript_text(model.events)

    case writer.(path, text <> "\n") do
      :ok -> App.notice(model, success_note)
      {:error, reason} -> App.notice(model, "write failed: #{inspect(reason)}")
    end
  end

  defp write_private(path, text) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        File.chmod(path, 0o600)
        result = IO.binwrite(io, text)
        File.close(io)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Write-and-close: clipboard tools (pbcopy/xclip/clip) commit on stdin
  # EOF. `Raxol.System.Clipboard` waits for an exit status its port can
  # never deliver (it closes the port before collecting), freezing the
  # update loop for its full timeout — so this seam feeds the tool
  # directly and treats a completed write as success.
  def default_clipboard(text) do
    case clipboard_command() do
      {:ok, {executable, args}} ->
        port = Port.open({:spawn_executable, executable}, [:binary, args: args])
        Port.command(port, text)
        Port.close(port)
        :ok

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  def clipboard_command do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"pbcopy", []}
        {:unix, _} -> {"xclip", ["-selection", "clipboard"]}
        {:win32, _} -> {"clip", []}
      end

    case System.find_executable(command) do
      nil -> {:error, {:clipboard_tool_missing, command}}
      path -> {:ok, {path, args}}
    end
  end

  defp copy_last_answer(model) do
    case model.messages
         |> Enum.reverse()
         |> Enum.find(&(&1.role == :assistant)) do
      nil ->
        App.notice(model, "no assistant reply to copy yet")

      %{content: content} ->
        case model.clipboard.(content) do
          :ok ->
            App.notice(model, "copied last reply (#{byte_size(content)} bytes)")

          {:error, reason} ->
            App.notice(model, "copy failed: #{inspect(reason)}")
        end
    end
  end

  @find_match_cap 8

  defp find_in_transcript(model, ""), do: App.notice(model, "usage: /find <text>")

  defp find_in_transcript(model, needle) do
    down_needle = String.downcase(needle)

    matches =
      Projection.project(model.events).blocks
      |> Enum.with_index(1)
      |> Enum.filter(fn {block, _index} ->
        block
        |> Block.search_text()
        |> String.downcase()
        |> String.contains?(down_needle)
      end)

    case matches do
      [] ->
        App.notice(model, "no matches for \"#{needle}\"")

      matches ->
        lines =
          matches
          |> Enum.take(@find_match_cap)
          |> Enum.map(fn {block, index} ->
            "#{index}. [#{block.kind}] " <>
              excerpt(Block.search_text(block), needle)
          end)

        header = "#{length(matches)} match(es) for \"#{needle}\":"
        App.notice(model, Enum.join([header | lines], "\n"))
    end
  end

  # A one-line window around the first hit, newlines flattened. The
  # caseless regex yields a BYTE offset that is a codepoint boundary in
  # the ORIGINAL string (a byte offset into a downcased copy is neither,
  # and grapheme-slicing with it shifts or empties the window on any
  # multibyte text — em dashes are everywhere in LLM replies).
  defp excerpt(text, needle) do
    flat = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    with {:ok, pattern} <- Regex.compile(Regex.escape(needle), "iu"),
         [{byte_start, _len}] <- Regex.run(pattern, flat, return: :index) do
      lead =
        flat
        |> binary_part(0, byte_start)
        |> String.graphemes()
        |> Enum.take(-20)

      rest = binary_part(flat, byte_start, byte_size(flat) - byte_start)
      ellipsis = if byte_start > 0 and length(lead) == 20, do: "…", else: ""
      ellipsis <> Enum.join(lead) <> String.slice(rest, 0, 70)
    else
      _no_match -> String.slice(flat, 0, 70)
    end
  end

  # -- /share -----------------------------------------------------------------

  @doc false
  # Treat a blank or too-short share secret as unconfigured (nil): a
  # declared-but-empty RAXOL_SHARE_SECRET is "" (truthy), and an empty/short
  # HMAC key is offline-forgeable, so /share must fall back to "not configured"
  # rather than mint a weak token. Length threshold lives in ShareToken.
  def normalize_share_secret(secret) do
    if Raxol.Agent.Code.ShareToken.secret_ok?(secret), do: secret, else: nil
  end

  # `/share` mints a signed, expiring read-only token for THIS session.
  # The journal is what the viewer replays, so it is ensured (and
  # backfilled) here — a share of a never-journaled session would
  # otherwise open empty.
  defp share_session(%{share_secret: nil} = model) do
    App.notice(
      model,
      "sharing not configured — set RAXOL_SHARE_SECRET (>= 32 bytes) on the " <>
        "host (and mount Raxol.Agent.Code.ShareLive in a web app)"
    )
  end

  defp share_session(model) do
    if Raxol.Agent.Code.ShareToken.valid_session_id?(model.session_key) and
         Raxol.Agent.Code.ShareToken.valid_scope?(model.share_scope) do
      mint_share(model)
    else
      # A session_key with a `:` or other non-id character (e.g. a colon-laden
      # /resume argument) would mint a token that can never verify. Refuse at
      # the source with an actionable message rather than print a dead link.
      App.notice(
        model,
        "this session's id can't be shared — resume or fork it under a " <>
          "plain id (letters, digits, . _ -) first"
      )
    end
  end

  defp mint_share(model) do
    model =
      case App.ensure_journal(model) do
        {:ok, journaled} -> journaled
        {:error, _reason} -> model
      end

    token =
      Raxol.Agent.Code.ShareToken.sign(model.session_key, model.share_secret,
        scope: model.share_scope
      )

    # "follows this session live" is the part that surprises: the viewer
    # attaches at the high-watermark and keeps receiving, so the link shares
    # everything typed for the next 24h, not a snapshot of the scrollback.
    case model.share_base_url do
      nil ->
        App.notice(
          model,
          "share token (read-only, follows this session live for 24h): #{token}"
        )

      base ->
        App.notice(
          model,
          "read-only link (follows this session live for 24h): " <>
            "#{String.trim_trailing(base, "/")}/#{token}"
        )
    end
  end

  # -- /model -----------------------------------------------------------------

  # `/model` with no arg on a connected provider fetches its model list and
  # opens a selectable picker; otherwise it just shows the current model.
  defp set_model(%{executor: %{}} = model, "") do
    if App.provider_ready?(model),
      do: open_model_picker(model),
      else: model_usage(model)
  end

  defp set_model(model, ""), do: model_usage(model)

  defp set_model(model, name) do
    # Clears any unpriced-model halt: naming a model is one of the two fixes
    # the halt notice points at, so it has to actually unblock the session.
    App.notice(
      %{model | model_override: name, unpriced_model: nil},
      "model set to #{name}"
    )
  end

  defp model_usage(model),
    do:
      App.notice(
        model,
        "usage: /model <name>  (current: #{model.model_override || "default"})"
      )

  defp open_model_picker(%{models_ref: ref} = model) when is_reference(ref),
    do: App.put_status(model, "already fetching models…")

  defp open_model_picker(model) do
    ref = make_ref()
    model.models_fetcher.(models_fetch_opts(model), ref, self())
    %{model | models_ref: ref} |> App.put_status("fetching models…")
  end

  # The connected executor's backend opts, with `:provider` pinned so the
  # model-list endpoint is chosen by the actual backend, not a URL guess, and
  # `:receive_timeout` pinned to the same wall bound `bounded/3` applies.
  # Without that the backend's own default (30s) sat above the outer bound,
  # so the outer one always fired first and the inner one was configuration
  # that could never take effect.
  defp models_fetch_opts(%{executor: executor}) do
    executor
    |> Raxol.Agent.ExecutorConfig.to_backend_opts()
    |> Keyword.put(:provider, executor.backend)
    |> Keyword.put(:receive_timeout, @fetch_timeout_ms)
  end

  @doc false
  # Default fetcher: list the provider's models off the app process (so a slow
  # endpoint never blocks the TUI); the outcome rides back as a `:models_list`
  # message `App.update/2` folds. The spawned process is unlinked; `app` must
  # be the App process.
  def default_models_fetcher(opts, ref, app) do
    fetch_async(app, :models_list, ref, fn ->
      Raxol.Agent.Backend.HTTP.list_models(opts)
    end)
  end

  @doc false
  def apply_models_result(model, {:ok, [_ | _] = ids}) do
    if Wizard.modal_wizard?(model) do
      # A modal step (masked credential entry) owns the screen; opening
      # the picker over it would discard half-typed secret input. Same rule
      # as apply_sessions_result/2.
      %{model | models_ref: nil, status_line: nil}
    else
      entries = Enum.map(ids, &%{model: &1, label: &1})

      %{
        model
        | models_ref: nil,
          status_line: nil,
          wizard: %{
            step: :models,
            entries: entries,
            cursor: model_cursor(entries, model.model_override)
          }
      }
    end
  end

  def apply_models_result(model, {:ok, []}),
    do:
      App.notice(
        %{model | models_ref: nil, status_line: nil},
        "no models returned — usage: /model <name>"
      )

  def apply_models_result(model, :unsupported),
    do:
      App.notice(
        %{model | models_ref: nil, status_line: nil},
        "model listing unavailable for this provider — usage: /model <name>"
      )

  def apply_models_result(model, {:error, reason}),
    do:
      App.notice(
        %{model | models_ref: nil, status_line: nil},
        "couldn't fetch models: #{fetch_failure(reason)} — usage: /model <name>"
      )

  # Start the cursor on the current model when it's in the list, else the top.
  defp model_cursor(entries, current) do
    case Enum.find_index(entries, &(&1.model == current)) do
      nil -> 0
      index -> index
    end
  end

  # -- /compact /context /usage -----------------------------------------------

  # Heuristic context shrink: keep the last few exchanges, replace the rest
  # with a marker. Not a semantic summary — an honest size reducer.
  defp compact(model) do
    keep = 6
    count = length(model.messages)

    if count <= keep do
      App.notice(model, "nothing to compact (#{count} messages)")
    else
      {older, recent} = Enum.split(model.messages, count - keep)

      marker = %{
        role: :system,
        content: "[#{length(older)} earlier messages compacted]"
      }

      model = App.persist(%{model | messages: [marker | recent]})
      App.notice(model, "compacted #{length(older)} messages")
    end
  end

  defp context_text(model) do
    {_turns, usage} = fold_usage(model.events)

    "messages: #{length(model.messages)} · events: #{length(model.events)} · " <>
      "tokens: #{usage.input_tokens} in / #{usage.output_tokens} out · " <>
      "plan: #{if model.plan_mode, do: "on", else: "off"} · " <>
      "model: #{model.model_override || "default"} · session: #{model.session_key}"
  end

  # Session token totals folded from the turn_completed events the model
  # already holds (the same events the transcript rebuilds from), so /usage
  # works on a resumed session too. The cost is the sum of each turn priced
  # exactly as the ledger priced it; a wired Payments ledger adds the
  # shared-budget totals (LLM + payment spend together).
  defp usage_text(model) do
    {turns, usage} = fold_usage(model.events)
    {cost, unpriced} = session_cost(model, model.events)

    base =
      "turns: #{turns} · input tokens: #{usage.input_tokens} · " <>
        "output tokens: #{usage.output_tokens}"

    cost_part =
      cond do
        unpriced > 0 and unpriced == turns ->
          " · cost: unknown model — set RAXOL_COST_PER_MTOK_IN/OUT"

        unpriced > 0 ->
          " · est. cost: $#{format_usd(cost)} (#{unpriced} of #{turns} turns " <>
            "unpriced — set RAXOL_COST_PER_MTOK_IN/OUT)"

        true ->
          " · est. cost: $#{format_usd(cost)}"
      end

    ledger_part =
      case Raxol.Agent.Code.CostLedger.totals_text(
             model.ledger,
             model.ledger_agent_id,
             model.spending_policy
           ) do
        nil -> ""
        text -> " · " <> text
      end

    base <> cost_part <> ledger_part
  end

  defp format_usd(cost), do: :erlang.float_to_binary(cost, decimals: 4)

  defp fold_usage(events) do
    Enum.reduce(events, {0, %{input_tokens: 0, output_tokens: 0}}, fn
      %{type: :turn_completed, payload: payload}, {turns, acc} ->
        usage = Map.get(payload, :usage) || Map.get(payload, "usage") || %{}
        {turns + 1, Raxol.Agent.BenchmarkProfile.add_usage(acc, usage)}

      _event, acc ->
        acc
    end)
  end

  # Each turn priced the way `App.meter_usage/5` priced it: the same resolver,
  # on that turn's raw usage map, with the model that turn billed. Summing
  # the tokens and pricing the total once through the flat table -- what this
  # did before -- could not see a provider-reported cost or a cache split,
  # so the panel and the ledger disagreed on the same money by the factor
  # those two carry. Turns nothing could price are counted, not hidden.
  defp session_cost(model, events) do
    Enum.reduce(events, {0.0, 0}, fn
      %{type: :turn_completed, payload: payload}, {sum, unpriced} ->
        usage = Map.get(payload, :usage) || Map.get(payload, "usage") || %{}

        case App.turn_cost(model, usage, App.billed_model(model, payload)) do
          {_zero, :unknown} -> {sum, unpriced + 1}
          {cost, _source} -> {sum + cost, unpriced}
        end

      _event, acc ->
        acc
    end)
  end
end
