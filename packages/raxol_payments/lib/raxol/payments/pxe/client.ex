defmodule Raxol.Payments.Pxe.Client do
  @moduledoc """
  JSON-RPC 2.0 client for the pxe-bridge.

  pxe-bridge embeds an Aztec PXE and exposes it via HTTP. This client
  wraps the two RPC methods (`aztec_createNote`, `aztec_getVersion`)
  and the `/status` health endpoint.

  ## Configuration

      config = %{
        url: "http://127.0.0.1:8547",
        api_key: "optional-bearer-token"
      }

      {:ok, result} = Pxe.Client.create_note(config, %CreateNoteParams{...})

  `:req_options` is merged into the request last and is the seam a test or an
  example drives the bridge through without one running:

      config = %{url: "http://pxe.sim", req_options: [plug: fn conn -> ... end]}
  """

  alias Raxol.Payments.Pxe.Schemas.{CreateNoteParams, CreateNoteResult, HealthStatus}

  @type config :: %{
          url: String.t(),
          api_key: String.t() | nil,
          req_options: keyword()
        }

  @type error ::
          {:error, {:http, integer(), term()}}
          | {:error, {:rpc, integer(), term()}}
          | {:error, term()}

  @default_url "http://127.0.0.1:8547"

  @doc "Create a shielded note on Aztec L2 for a recipient."
  @spec create_note(config(), CreateNoteParams.t()) :: {:ok, CreateNoteResult.t()} | error()
  def create_note(config, %CreateNoteParams{} = params) do
    with :ok <- CreateNoteParams.validate(params) do
      rpc_call(config, "aztec_createNote", [CreateNoteParams.to_json(params)])
      |> handle_rpc_result(&CreateNoteResult.from_json/1)
    end
  end

  @doc "Get the connected Aztec node version."
  @spec get_version(config()) :: {:ok, String.t()} | error()
  def get_version(config) do
    rpc_call(config, "aztec_getVersion", [])
    |> handle_rpc_result(& &1)
  end

  @doc "Check bridge health via GET /status."
  @spec health(config()) :: {:ok, HealthStatus.t()} | error()
  def health(config) do
    config
    |> build_req()
    |> Req.get(url: "/status")
    |> handle_http_response(&HealthStatus.from_json/1)
  end

  # -- Private --

  defp rpc_call(config, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => System.unique_integer([:positive])
    }

    config
    |> build_req()
    |> Req.post(url: "/", json: body)
  end

  defp handle_rpc_result({:ok, %Req.Response{status: status, body: body}}, transform)
       when status in 200..299 do
    case body do
      %{"result" => result} ->
        {:ok, transform.(result)}

      %{"error" => %{"code" => code, "message" => msg}} ->
        {:error, {:rpc, code, msg}}

      %{"error" => %{"code" => code}} ->
        {:error, {:rpc, code, "unknown error"}}

      _ ->
        {:error, {:unexpected_response, body}}
    end
  end

  defp handle_rpc_result({:ok, %Req.Response{status: status, body: body}}, _transform) do
    {:error, {:http, status, body}}
  end

  defp handle_rpc_result({:error, reason}, _transform) do
    {:error, reason}
  end

  defp handle_http_response({:ok, %Req.Response{status: status, body: body}}, transform)
       when status in 200..299 do
    {:ok, transform.(body)}
  end

  defp handle_http_response({:ok, %Req.Response{status: status, body: body}}, _transform) do
    {:error, {:http, status, body}}
  end

  defp handle_http_response({:error, reason}, _transform) do
    {:error, reason}
  end

  defp build_req(config) do
    url = Map.get(config, :url, @default_url)
    headers = auth_headers(config)

    opts = [
      base_url: url,
      headers: headers,
      receive_timeout: 15_000
    ]

    opts =
      case Map.get(config, :retry) do
        false -> Keyword.put(opts, :retry, false)
        _ -> opts
      end

    # The transport seam, named the same as `Xochi.Client`'s so a caller that
    # already sims one bridge does not have to learn a second key. Merged last
    # and on top, so a test or an example can override `base_url` too; without
    # it this client could only ever be exercised against a dead port, which is
    # why nothing here had a success-path test.
    Req.new(Keyword.merge(opts, Map.get(config, :req_options, [])))
  end

  defp auth_headers(%{api_key: key}) when is_binary(key) and key != "" do
    [{"authorization", "Bearer #{key}"}]
  end

  defp auth_headers(_), do: []
end
