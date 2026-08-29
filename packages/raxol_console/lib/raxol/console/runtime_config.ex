defmodule Raxol.Console.RuntimeConfig do
  @moduledoc """
  Pure mapping from a parsed Console package (`Raxol.Earn.Console.Package`) plus
  deployment options into the config `Raxol.Console.Boot` starts a runtime from.

  The package carries persona + behavior (soul.md, AGENTS.md, tasks.json,
  skills); the deployment supplies credentials, channels, and inference (the
  Console injects these). This module merges them. It performs no I/O and starts
  nothing.

  Key mappings:

    * `soul.md` (+ `AGENTS.md` under an operating-rules heading) -> a single
      `:system_prompt` binary applied to every turn (both `Handler.Agent` and
      `Stream.run` take one binary), with an sha256 identity for a debug card.
    * each `tasks.json` task -> a `Raxol.Agent.Scheduler.create/2` attr map,
      keyed by task name (the stable job id, so reboots reconcile rather than
      duplicate).
    * `skills/` -> carried through for the skills store.
    * default MCP servers (`Raxol.Agent.McpBundle.default_servers/1`) -> specs
      the boot bundles as dynamic tools, unless disabled.
  """

  alias Raxol.Earn.Console.Package
  alias Raxol.Agent.McpBundle
  alias Raxol.Console.AppRegistry

  @type scheduler_job :: %{
          id: String.t(),
          prompt: String.t(),
          schedule: String.t(),
          skills: [String.t()],
          target: String.t() | nil,
          enabled: boolean()
        }

  @typedoc """
  Which gateway handler a chat turn runs.

    * `:chat` -- one `Raxol.Agent.Stream.run/2` per turn, persona applied
      automatically. The default, and what every current Console template needs.
    * `:app` -- a full TEA app per chat under `environment: :gateway`, so the
      model persists across turns.
  """
  @type handler_mode :: :chat | :app

  @typedoc """
  The resolved gateway authorization posture.

    * `:open` -- every connected platform is allowed for everyone. Reachable
      only by writing `pairing: :open`, so `declared?` is always true here.
    * `:enforce` -- `Raxol.Gateway.Pairing` decides, seeded from the three
      allowlists and extended at runtime by the DM pairing flow. `declared?`
      is false when no `:pairing` was set at all, which denies every route and
      is what `Raxol.Console.Boot` warns about at boot.
  """
  @type pairing :: %{
          mode: :open | :enforce,
          declared?: boolean(),
          allow_platforms: [atom()],
          allowed_users: [String.t()],
          platform_users: [{atom(), [String.t()]}]
        }

  defstruct system_prompt: nil,
            persona_sha256: nil,
            scheduler_jobs: [],
            skills: [],
            agent_opts: [],
            channels: [],
            mcp_servers: [],
            handler_mode: :chat,
            app_module: nil,
            idle_timeout: nil,
            max_sessions: nil,
            pairing: nil

  @type t :: %__MODULE__{
          system_prompt: String.t(),
          persona_sha256: String.t(),
          scheduler_jobs: [scheduler_job()],
          skills: [%{name: String.t(), skill_md: String.t()}],
          agent_opts: keyword(),
          channels: [term()],
          mcp_servers: [McpBundle.server_spec()],
          handler_mode: handler_mode(),
          app_module: module() | nil,
          idle_timeout: pos_integer() | nil,
          max_sessions: pos_integer() | nil,
          pairing: pairing()
        }

  @doc """
  Build a `%RuntimeConfig{}` from a package and deployment options.

  Options:

    * `:agent_opts` -- forwarded to the agent turn (`:executor`/`:backend`/...).
    * `:channels` -- gateway channel specs (deployment-supplied).
    * `:default_target` -- default `"platform:chat_id"` scheduled tasks deliver to.
    * `:mcp_servers` -- override the bundled MCP server specs.
    * `:bundle_default_mcp` -- default `true`; bundle the standard server set.
    * `:workspace` -- scopes the bundled filesystem server (default `"."`).
    * `:handler_mode` -- `:chat` (default) or `:app`; see `t:handler_mode/0`.
    * `:app_template` -- required in `:app` mode; a name resolved against
      `Raxol.Console.AppRegistry`.
    * `:idle_timeout` -- ms a chat may sit idle before its session stops
      (gateway default 10 minutes). A stopped session is rebuilt on the next
      message, so for `:chat` this costs nothing. For `:app` it discards the
      model the mode exists to persist, which makes the right value a property
      of the deployment's app rather than of the gateway.
    * `:max_sessions` -- concurrent chats the router will hold (gateway default
      1000); further chats are refused with `:max_sessions`.
    * `:pairing` -- who may open a chat; see "Authorization" below.

  `:handler_mode` and `:app_template` are read from the DEPLOYMENT options, never
  from the package. The package is untrusted input, and choosing which module
  runs per chat is not a decision it gets to make.

  ## Authorization

  `:pairing` has three states, and an omitted one denies:

      # unset -- enforced with nothing seeded: denies everyone, warned at boot
      # explicitly open, no warning: the operator has made this call
      pairing: :open

      # enforced; Raxol.Gateway.Pairing decides
      pairing: [
        allow_platforms: [:telegram],          # everyone on these platforms
        allowed_users: ["12345"],              # global allowlist
        platform_users: [discord: ["9876"]]    # per-platform allowlist
      ]

  `pairing: []` is enforced with nothing seeded: it denies everyone, and it
  admits nobody until an operator pairs them by hand. There is no `/pair` chat
  command -- a denial is decided before a session exists, so an unpaired sender
  cannot ask for a code through the chat. `Pairing.request_code/2` and
  `confirm/2` are reachable only out of band (a remote shell, or the
  deployment's own admin surface), and a self-service lane is something the feed
  loop builds with `Raxol.Console.Inbound.authorized?/2`. Do not reach for
  `pairing: []` expecting the pairing flow to be wired; seed `:allowed_users`
  with whoever should already be in.

  `:allowed_users` is NOT platform-scoped -- the id matches on every connected
  platform, whose id namespaces are unrelated. Prefer `:platform_users` when a
  deployment connects more than one. See `Raxol.Gateway.Pairing`.

  An unconfigured Console denies everyone, and `Raxol.Console.Boot` says so at
  boot. That locks out a deployment that never configured pairing, which is the
  intended trade: the alternative made silence the permissive answer, so a
  deployment could expose an agent's turns, tools and spend to anyone who could
  reach a connected platform without a single line of config saying so. A lockout
  is visible in one message; an open gate is discovered by whoever finds it first.
  Adding `pairing: :open` restores the old behaviour explicitly.

  Open mode is not a bypass. It is seeded into `Pairing`'s own start options as
  `allow_platforms:` over the CONNECTED platforms, so the gate runs identically
  in both modes, the posture is visible in the Pairing server's state, and a
  restart rebuilds it. A route on a platform the deployment never connected is
  denied even when open.

  ## Sizing an `:app` deployment

  The two timeout/limit keys are one decision in `:app` mode, not two. A `:chat`
  session is a process holding a message list; an `:app` session is a running
  TEA app -- a Lifecycle, a dispatcher, an engine and a buffer, roughly four to
  five processes plus the model. At the gateway's own defaults that is a ceiling
  of ~5000 processes, and raising `:idle_timeout` to keep models warm raises how
  many of them are live at once, because the two multiply: idle chats now hold
  their apps instead of being rebuilt on the next message.

  So a deployment that lengthens `:idle_timeout` for `:app` mode should size
  `:max_sessions` deliberately rather than inherit 1000.
  """
  @spec build(Package.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(package, opts \\ [])

  def build(%Package{} = pkg, opts) do
    with {:ok, persona} <- persona(pkg),
         {:ok, mode, app_module} <- handler(opts),
         {:ok, idle_timeout} <- pos_integer(opts, :idle_timeout, :invalid_idle_timeout),
         {:ok, max_sessions} <- pos_integer(opts, :max_sessions, :invalid_max_sessions),
         {:ok, pairing} <- pairing(opts) do
      {:ok,
       %__MODULE__{
         system_prompt: persona,
         persona_sha256: sha256(persona),
         scheduler_jobs: scheduler_jobs(pkg, opts),
         skills: pkg.skills,
         agent_opts: Keyword.get(opts, :agent_opts, []),
         channels: Keyword.get(opts, :channels, []),
         mcp_servers: mcp_servers(opts),
         handler_mode: mode,
         app_module: app_module,
         idle_timeout: idle_timeout,
         max_sessions: max_sessions,
         pairing: pairing
       }}
    end
  end

  def build(other, _opts), do: {:error, {:not_a_package, other}}

  @doc """
  The `Raxol.Gateway` handler spec this runtime boots.

  `:chat` runs the stateless agent loop with the resolved persona applied per
  turn. `:app` runs a per-chat TEA app, and threads the persona through
  `:lifecycle_opts` -- `Raxol.Gateway.Handler.Lifecycle` appends those to
  `Raxol.Core.Runtime.Lifecycle.start_link/2`, which hands them to the app as
  `init(%{options: opts})`. That is the only seam a TEA app has for the persona:
  unlike the chat loop it weaves the system prompt into its own model and backend
  calls rather than getting it applied for free.

  `agent_opts` rides the same seam. The boot resolves them either way -- bundled
  MCP servers run as supervised subprocesses and the skills store is started
  before the gateway -- so an `:app` runtime that dropped them would pay for a
  toolset no chat could reach. A TEA app is free to ignore the key; it is not
  free to have it silently withheld.

  ## What an `:app` module is trusted with

  Handing over `agent_opts` hands over capability, so it is worth stating plainly
  what crosses. `:actions` is the fully resolved toolset, including the bundled
  filesystem server scoped to `:workspace`, and `:context` carries the skills
  store. In `:chat` mode those are reached only through `Raxol.Agent.Stream`,
  which gates each call per turn. `:app` mode has no equivalent: the app receives
  the list and whatever it does with it is unmediated.

  That is why `Raxol.Console.AppRegistry` exists and why the package cannot name
  a module. An `:app` template is operator-authored code running with the
  runtime's own authority, and it should be read as such -- not as a sandbox.
  """
  @spec handler_spec(t(), keyword()) :: {module(), keyword()}
  def handler_spec(%__MODULE__{handler_mode: :app} = rc, agent_opts) do
    {Raxol.Gateway.Handler.Lifecycle,
     [
       app_module: rc.app_module,
       lifecycle_opts: [system_prompt: rc.system_prompt, agent_opts: agent_opts]
     ]}
  end

  def handler_spec(%__MODULE__{} = rc, agent_opts) do
    {Raxol.Gateway.Handler.Agent, [system_prompt: rc.system_prompt, agent_opts: agent_opts]}
  end

  # -- handler mode ----------------------------------------------------------

  defp handler(opts) do
    case Keyword.get(opts, :handler_mode, :chat) do
      :chat -> {:ok, :chat, nil}
      :app -> resolve_app(Keyword.get(opts, :app_template))
      other -> {:error, {:unknown_handler_mode, other}}
    end
  end

  defp resolve_app(nil), do: {:error, :missing_app_template}

  defp resolve_app(name) do
    with {:ok, module} <- AppRegistry.fetch(name), do: {:ok, :app, module}
  end

  # -- authorization ---------------------------------------------------------

  @pairing_keys [:allow_platforms, :allowed_users, :platform_users]

  # An omitted `:pairing` denies. It is the only posture that can be reached by
  # writing nothing, so it is the one that must not grant anything: silence is
  # not consent to expose an agent's turns, tools and spend to every sender on
  # every connected platform. Opening the gate takes the word `:open`.
  defp pairing(opts) do
    case Keyword.get(opts, :pairing) do
      nil -> {:ok, undeclared_enforce()}
      :open -> {:ok, open(true)}
      list when is_list(list) -> enforce(list)
      other -> {:error, {:invalid_pairing, other}}
    end
  end

  # Same shape `enforce([])` produces, but `declared?: false` so Boot can say
  # WHY everyone is being denied. An operator who wrote `pairing: []` meant it
  # and is not nagged; silence is.
  defp undeclared_enforce do
    %{
      mode: :enforce,
      declared?: false,
      allow_platforms: [],
      allowed_users: [],
      platform_users: []
    }
  end

  defp open(declared?) do
    %{
      mode: :open,
      declared?: declared?,
      allow_platforms: [],
      allowed_users: [],
      platform_users: []
    }
  end

  # A keyword list is the enforcing form, including the empty one. Unknown keys
  # are refused rather than ignored: a typo'd `allowed_user:` would otherwise
  # seed nothing and read as a deliberate deny-all.
  defp enforce(list) do
    with :ok <- known_keys(list),
         {:ok, platforms} <- atom_list(list, :allow_platforms),
         {:ok, users} <- string_list(list, :allowed_users),
         {:ok, platform_users} <- platform_users(list) do
      {:ok,
       %{
         mode: :enforce,
         declared?: true,
         allow_platforms: platforms,
         allowed_users: users,
         platform_users: platform_users
       }}
    end
  end

  defp known_keys(list) do
    case Enum.reject(Keyword.keys(list), &(&1 in @pairing_keys)) do
      [] -> :ok
      unknown -> {:error, {:unknown_pairing_keys, unknown}}
    end
  end

  # `nil`, `true` and `false` are atoms, and a platform key holding one of them
  # names no channel and grants nothing -- the silent-lockout shape `known_keys/1`
  # refuses one level up. `platform: nil` is the likely way in, from a lookup that
  # missed. Refuse it here rather than warning about it at boot.
  defp atom_list(list, key) do
    values = Keyword.get(list, key, [])

    if is_list(values) and Enum.all?(values, &platform_atom?/1),
      do: {:ok, values},
      else: {:error, {:invalid_pairing, {key, values}}}
  end

  defp platform_atom?(value), do: is_atom(value) and value not in [nil, true, false]

  # User ids are stringified here rather than at the Pairing call site, because
  # `Pairing.allow/3` stringifies too and an integer Telegram id configured as an
  # integer must land in the same set the route's stringified id is checked
  # against.
  defp string_list(list, key) do
    values = Keyword.get(list, key, [])

    if is_list(values) and Enum.all?(values, &scalar_id?/1),
      do: {:ok, Enum.map(values, &to_string/1)},
      else: {:error, {:invalid_pairing, {key, values}}}
  end

  defp platform_users(list) do
    entries = Keyword.get(list, :platform_users, [])

    if Keyword.keyword?(entries) do
      Enum.reduce_while(entries, {:ok, []}, &reduce_platform_users/2)
    else
      {:error, {:invalid_pairing, {:platform_users, entries}}}
    end
  end

  # Duplicate platform keys are carried through as written; `Pairing` unions them
  # when it seeds, so naming a platform twice adds both sets rather than keeping
  # only the last.
  defp reduce_platform_users({platform, users}, {:ok, acc}) do
    if platform_atom?(platform) and is_list(users) and Enum.all?(users, &scalar_id?/1),
      do: {:cont, {:ok, acc ++ [{platform, Enum.map(users, &to_string/1)}]}},
      else: {:halt, {:error, {:invalid_pairing, {:platform_users, platform, users}}}}
  end

  defp scalar_id?(value), do: is_binary(value) or is_integer(value)

  # -- router bounds ---------------------------------------------------------

  # Validated rather than defaulted: a bound that is not a positive integer
  # would otherwise reach the session's `Process.send_after/3` and fail there,
  # or -- worse for a string -- compare as a term and never fire the branch it
  # feeds. `nil` is the honest "unset", leaving the gateway's own default in
  # force rather than pinning a second copy of that number here.
  defp pos_integer(opts, key, error_tag) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {error_tag, other}}
    end
  end

  # -- persona ---------------------------------------------------------------

  defp persona(%Package{soul_md: soul} = pkg) when is_binary(soul) and soul != "" do
    base = String.trim_trailing(soul)

    text =
      case pkg.agents_md do
        agents when is_binary(agents) and agents != "" ->
          base <> "\n\n## Operating rules\n\n" <> String.trim(agents)

        _ ->
          base
      end

    {:ok, text}
  end

  defp persona(_pkg), do: {:error, :missing_soul}

  # -- scheduler jobs --------------------------------------------------------

  defp scheduler_jobs(%Package{tasks: tasks}, opts) do
    target = Keyword.get(opts, :default_target)

    Enum.map(tasks, fn task ->
      %{
        id: task.name,
        prompt: task.prompt,
        schedule: task.cron,
        skills: [],
        target: target,
        enabled: true
      }
    end)
  end

  # -- mcp servers -----------------------------------------------------------

  defp mcp_servers(opts) do
    cond do
      servers = Keyword.get(opts, :mcp_servers) ->
        servers

      Keyword.get(opts, :bundle_default_mcp, true) ->
        McpBundle.default_servers(workspace: Keyword.get(opts, :workspace, "."))

      true ->
        []
    end
  end

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
