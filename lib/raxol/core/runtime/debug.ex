defmodule Raxol.Core.Runtime.Debug do
  @moduledoc """
  Debug logging functionality for the Raxol runtime.
  """

  @callback debug(message :: String.t()) :: :ok
  @callback info(message :: String.t()) :: :ok
  @callback warn(message :: String.t()) :: :ok
  @callback error(message :: String.t()) :: :ok

  @behaviour __MODULE__


  @impl __MODULE__
  def debug(message), do: Raxol.Core.Runtime.Log.debug(message)

  @impl __MODULE__
  def info(message), do: Raxol.Core.Runtime.Log.info(message)

  @impl __MODULE__
  def warn(message),
    do: Raxol.Core.Runtime.Log.warning(message, %{module: __MODULE__})

  @impl __MODULE__
  def error(message),
    do: Raxol.Core.Runtime.Log.error(message, %{module: __MODULE__})
end
