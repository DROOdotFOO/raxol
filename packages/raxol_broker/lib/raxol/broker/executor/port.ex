defmodule Raxol.Broker.Executor.Port do
  @moduledoc """
  The executor's write-capable session: the only channel through which a
  `review_*` or order tool is called.

  `Raxol.Broker.MCP.Client` stays read-only. A port is a separate session
  that `Raxol.Broker.Executor` starts and keeps in its own state; nothing
  else in the VM holds it. `Raxol.Broker.Executor.Port.MCP` is the
  implementation over `Raxol.MCP.Client`, and it decides whether the session
  is live from its spec before connecting.

  A port is `{module, handle}`. `call/4` returns what `Raxol.MCP.Client.call_tool/4`
  returns: `{:ok, %{content: [...], is_error: boolean}}`, `{:error, %{"code" => _}}`
  for a JSON-RPC error the server answered, or `{:error, reason}` when the
  call did not complete.
  """

  @type t :: {module(), term()}

  @callback call(handle :: term(), tool :: String.t(), args :: map(), timeout()) ::
              {:ok, map()} | {:error, term()}
  @callback stop(handle :: term()) :: :ok

  @doc """
  Call `tool` through `port`. The caller giving up after `timeout` is
  `{:error, :timeout}`; any other exit of the port is
  `{:error, {:port_down, reason}}`.
  """
  @spec call(t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call({module, handle}, tool, args, timeout) do
    module.call(handle, tool, args, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, reason -> {:error, {:port_down, reason}}
  end

  @doc "Close `port`."
  @spec stop(t()) :: :ok
  def stop({module, handle}), do: module.stop(handle)
end
