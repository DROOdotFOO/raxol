defmodule Raxol.Agent.Backend.OmpGateway do
  @moduledoc """
  Model access through OMP's `omp auth-gateway stdio` (ADR-0042, decision 4).

  The gateway reaches every provider OMP is logged in to, role selectors such
  as `@smol` included, with OMP's own credentials. Requests are Anthropic
  Messages bodies built by `Raxol.Agent.Backend.Anthropic.Wire`, sent with
  `stream: false` and an explicit `max_tokens` (the gateway requires one;
  default as for `Raxol.Agent.Backend.HTTP`: `AI_MAX_TOKENS`, else 4096).

  Selected only by name (`:omp_gateway`, catalog kind `:gateway`), never
  auto-detected. The framework drives tool calls (`handles_tools_internally?/0`
  is false, so `SpendGate` sees every one). No `:streaming`: the gateway
  returns a streamed reply as one string after the stream ends.

  `:model` is required (owner decision): `complete/2` without one returns
  `{:error, :model_required}` before any request, never `Wire`'s direct-API
  default, which through the gateway would be billed to whichever OMP
  account resolves that id.

  ## The binary

  `config :raxol_agent, :omp_gateway, path: "/abs/path/to/omp"`, else `omp`
  on an absolute `PATH` entry. It is refused unless it is a regular file
  owned by this account or by root and neither group- nor other-writable:
  whoever can rewrite it holds every credential OMP has. The directory
  holding it must be sticky, or owned by this account or root and neither
  group- nor other-writable (owner decision; `OperatorFile.trusted_dir?/2`),
  or another account could rename a replacement into place between the
  check and the spawn. A symlink is followed, and the directory holding
  each link is vetted as well as the target's.

  ## Pricing

  The gateway drops HTTP headers, so its cost header never arrives. A reply is
  priced by `Raxol.Agent.LlmPrices` on the model that answered:
  `metadata.cost_usd` and `metadata.cost_source`, or `cost_usd: nil,
  cost_source: :unpriced` beside the token `usage` for a model the table does
  not know.

  ## Errors

  None carries a request or reply body.

  The request:

    * `:model_required`: `complete/2` without a `:model`.
    * `{:invalid_request, exception_module}`: the body cannot be JSON (a
      string that is not UTF-8, say); `{:invalid_request, :timeout}`: the
      `:timeout` (ms, default 120 s) is not an integer from 0 to 2^32 - 1.
      Neither reaches the gateway.

  The reply:

    * `{:http_error, status, error_type}`: a non-2xx reply, with the body's
      `error.type` (or nil).
    * A string: a 2xx `/v1/messages` body `Wire` cannot parse, as its
      keys-only marker.
    * `{:gateway_timeout, ms}`: no reply by the deadline.

  The gateway process (the next request starts a new one):

    * `{:gateway_exit, status}`: it exited with the request pending. An
      integer is its exit status; any other term is the reason its port
      closed.
    * `:gateway_ready_timeout`: it printed no ready line in time (killed).
    * `{:gateway_refused, reason}`: its first line was not a ready line
      (`:invalid_ready_line`) or its version is refused
      (`{:unsupported_major, found, tested}`, `Raxol.Agent.OMP.Version`).
    * `{:gateway_spawn_failed, reason}`: the port could not be opened.
    * `:gateway_not_started`: no server is running; `:gateway_down`: the
      server itself stopped during the call.

  The binary (`resolve_binary/1`): `:omp_not_found`,
  `{:omp_path_not_absolute, path}`, `{:omp_not_a_file, type}`,
  `{:omp_stat_failed, posix}`, `{:omp_not_owned, uid}`,
  `{:omp_writable, mode}`, `{:omp_dir_untrusted, dir, refusal}` (an
  `OperatorFile` refusal) and `:omp_symlink_loop`.
  """

  @behaviour Raxol.Agent.AIBackend

  alias Raxol.Agent.Backend.HTTP
  alias Raxol.Agent.Backend.OmpGateway.Codec
  alias Raxol.Agent.Backend.OmpGateway.Server
  alias Raxol.Agent.OperatorFile

  @default_timeout_ms 120_000
  @max_links 40

  @doc "Supervision spec for the gateway server (see `OmpGateway.Server`)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Server.child_spec(opts)

  @impl true
  def complete(messages, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :max_tokens, &HTTP.default_max_tokens/0)

    with :ok <- require_model(opts),
         {:ok, body} <-
           request(:post, "/v1/messages", Codec.messages_body(messages, opts), opts) do
      Codec.parse_messages(body)
    end
  end

  # Never `Anthropic.Wire`'s direct-API default: through the gateway a bare
  # id is billed to whichever OMP account resolves it.
  defp require_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> :ok
      _absent -> {:error, :model_required}
    end
  end

  @doc """
  One raw gateway request: `{:ok, body}` for a 2xx, else an error as in the
  moduledoc. Opts: `:timeout` (ms), `:server` (default the supervised one).
  """
  @spec request(Codec.method(), String.t(), map() | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(method, path, body, opts \\ []) do
    server = Keyword.get(opts, :server, Server)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    with {:ok, response} <- Server.request(server, method, path, body, timeout) do
      Codec.result(response)
    end
  end

  @doc "The model ids the gateway serves (`GET /v1/models`, no model call)."
  @spec list_models(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(opts \\ []) do
    with {:ok, body} <- request(:get, "/v1/models", nil, opts) do
      {:ok, Codec.model_ids(body)}
    end
  end

  @impl true
  def available?, do: match?({:ok, _path}, resolve_binary(nil))

  @impl true
  def name, do: "OMP auth-gateway"

  @impl true
  def capabilities, do: [:completion, :tool_use]

  @impl true
  def handles_tools_internally?, do: false

  @doc """
  The `omp` binary to run: `path` if given, else the configured `:path`,
  else `omp` on an absolute `PATH` entry, vetted as in the moduledoc.
  """
  @spec resolve_binary(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def resolve_binary(path) do
    case path || configured_path() do
      nil -> find_on_path()
      path -> vet(path)
    end
  end

  defp configured_path do
    :raxol_agent |> Application.get_env(:omp_gateway, []) |> Keyword.get(:path)
  end

  # Relative PATH entries resolve against the BEAM's cwd, where a cloned
  # repository could plant its own `omp`.
  defp find_on_path do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    dirs =
      (System.get_env("PATH") || "")
      |> String.split(separator)
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.join(separator)

    case :os.find_executable(~c"omp", String.to_charlist(dirs)) do
      false -> {:error, :omp_not_found}
      found -> found |> List.to_string() |> vet()
    end
  end

  defp vet(path) do
    if Path.type(path) == :absolute do
      vet_link(path, @max_links)
    else
      {:error, {:omp_path_not_absolute, path}}
    end
  end

  # Every name on the way to the file is vetted with the directory holding
  # it: a symlink's own directory as well as its target's, so neither the
  # link nor the file can be renamed over between this check and the spawn.
  defp vet_link(path, hops) do
    with :ok <- vet_dir(Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> follow(path, hops)
        {:ok, %File.Stat{type: :regular} = stat} -> vet_file(stat, path)
        {:ok, %File.Stat{type: type}} -> {:error, {:omp_not_a_file, type}}
        {:error, :enoent} -> {:error, :omp_not_found}
        {:error, reason} -> {:error, {:omp_stat_failed, reason}}
      end
    end
  end

  defp follow(_path, 0), do: {:error, :omp_symlink_loop}

  defp follow(path, hops) do
    case File.read_link(path) do
      {:ok, target} ->
        with {:ok, _target} <- vet_link(Path.expand(target, Path.dirname(path)), hops - 1),
             do: {:ok, path}

      {:error, reason} ->
        {:error, {:omp_stat_failed, reason}}
    end
  end

  # Sticky, or owned by this account or root and neither group- nor
  # other-writable (`OperatorFile.trusted_dir?/2`).
  defp vet_dir(dir) do
    case OperatorFile.trusted_dir?(dir, allow_root: true) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :omp_not_found}
      {:error, refusal} -> {:error, {:omp_dir_untrusted, dir, refusal}}
    end
  end

  defp vet_file(stat, path) do
    case OperatorFile.owned_unshared(stat, allow_root: true) do
      :ok -> {:ok, path}
      {:error, {:not_owned, owner}} -> {:error, {:omp_not_owned, owner}}
      {:error, {:group_or_other_writable, mode}} -> {:error, {:omp_writable, mode}}
    end
  end
end
