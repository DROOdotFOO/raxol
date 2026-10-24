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

  ## The binary

  `config :raxol_agent, :omp_gateway, path: "/abs/path/to/omp"`, else `omp`
  on an absolute `PATH` entry. It is refused unless it is a regular file
  owned by this account or by root and neither group- nor other-writable:
  whoever can rewrite it holds every credential OMP has.

  ## Pricing

  The gateway drops HTTP headers, so its cost header never arrives. A reply is
  priced by `Raxol.Agent.LlmPrices` on the model that answered:
  `metadata.cost_usd` and `metadata.cost_source`, or `cost_usd: nil,
  cost_source: :unpriced` beside the token `usage` for a model the table does
  not know.

  ## Errors

  `{:error, {:http_error, status, error_type}}` for a non-2xx reply (never
  its body), `{:error, {:gateway_timeout, ms}}` past the deadline (`:timeout`,
  default 120 s), `{:error, {:gateway_exit, status}}` when the gateway exits
  with the request pending (the next request starts a new one), and the
  binary and version refusals from `resolve_binary/1` and
  `Raxol.Agent.OMP.Version`.
  """

  @behaviour Raxol.Agent.AIBackend

  import Bitwise, only: [band: 2]

  alias Raxol.Agent.Backend.HTTP
  alias Raxol.Agent.Backend.OmpGateway.Codec
  alias Raxol.Agent.Backend.OmpGateway.Server
  alias Raxol.Agent.OperatorFile

  @default_timeout_ms 120_000
  @group_other_write 0o022

  @doc "Supervision spec for the gateway server (see `OmpGateway.Server`)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Server.child_spec(opts)

  @impl true
  def complete(messages, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :max_tokens, &HTTP.default_max_tokens/0)

    with {:ok, body} <- request(:post, "/v1/messages", Codec.messages_body(messages, opts), opts) do
      Codec.parse_messages(body)
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
      path |> File.stat() |> vet_stat(path)
    else
      {:error, {:omp_path_not_absolute, path}}
    end
  end

  defp vet_stat({:ok, %File.Stat{type: :regular} = stat}, path) do
    case trusted(stat) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vet_stat({:ok, %File.Stat{type: type}}, _path), do: {:error, {:omp_not_a_file, type}}
  defp vet_stat({:error, :enoent}, _path), do: {:error, :omp_not_found}
  defp vet_stat({:error, reason}, _path), do: {:error, {:omp_stat_failed, reason}}

  # Windows reports neither a meaningful uid nor POSIX mode bits.
  defp trusted(%File.Stat{uid: owner, mode: mode}) do
    uid = OperatorFile.uid()
    permissions = band(mode, 0o777)

    cond do
      match?({:win32, _}, :os.type()) -> :ok
      uid != :unknown and owner not in [uid, 0] -> {:error, {:omp_not_owned, owner}}
      band(permissions, @group_other_write) != 0 -> {:error, {:omp_writable, permissions}}
      true -> :ok
    end
  end
end
