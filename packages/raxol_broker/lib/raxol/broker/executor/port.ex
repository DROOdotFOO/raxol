defmodule Raxol.Broker.Executor.Port do
  @moduledoc """
  The executor's write-capable session: the only channel through which a
  `review_*`, `place_*` or `cancel_*` tool is called.

  `Raxol.Broker.MCP.Client` stays read-only. A port is a separate session
  that `Raxol.Broker.Executor` starts and keeps in its own state; nothing
  else in the VM holds it. `Raxol.Broker.Executor.Port.MCP` is the
  implementation over `Raxol.MCP.Client`.

  A port is `{module, handle}`. `call/4` returns what `Raxol.MCP.Client.call_tool/4`
  returns: `{:ok, %{content: [...], is_error: boolean}}`, `{:error, %{"code" => _}}`
  for a JSON-RPC error the server answered, or `{:error, reason}` when the
  call did not complete (timeout, transport failure).

  `live?/1` is true when the session reaches a real brokerage. The executor
  refuses a live port in dry-run mode.
  """

  @type t :: {module(), term()}

  @callback call(handle :: term(), tool :: String.t(), args :: map(), timeout()) ::
              {:ok, map()} | {:error, term()}
  @callback live?(handle :: term()) :: boolean()
  @callback stop(handle :: term()) :: :ok

  @doc "Call `tool` through `port`. A port process that exits is `{:error, {:port_down, reason}}`."
  @spec call(t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call({module, handle}, tool, args, timeout) do
    module.call(handle, tool, args, timeout)
  catch
    :exit, reason -> {:error, {:port_down, reason}}
  end

  @doc "Does `port` reach a real brokerage?"
  @spec live?(t()) :: boolean()
  def live?({module, handle}), do: module.live?(handle)

  @doc "Close `port`."
  @spec stop(t()) :: :ok
  def stop({module, handle}), do: module.stop(handle)
end
