defmodule Raxol.Console.AppRegistry do
  @moduledoc """
  Allowlist of TEA app modules a Console runtime may boot in `:app` handler mode.

  A Console package is untrusted input: it is authored elsewhere and loaded by
  `Raxol.Earn.Console.Package`. Selecting a TEA app therefore goes through a
  NAME, resolved against a map the deployment configures, rather than a module
  the package could name directly. A name that is not in the map resolves to
  nothing at all -- there is no `String.to_atom/1` on this path, so no input can
  reach a module the operator did not list.

  The map is also the capability gate. It is empty by default, so `:app` mode is
  unavailable until an operator registers at least one template, and the default
  Console runtime stays the stateless `Handler.Agent` chat loop.

      config :raxol_console, :app_templates, %{
        "dashboard" => MyConsole.Apps.Dashboard,
        "trading-desk" => MyConsole.Apps.TradingDesk
      }

  See `Raxol.Console.RuntimeConfig.handler_spec/2` for what a resolved module is
  then booted into, and GitHub #763 for why the package format does not carry a
  TEA app of its own.
  """

  @type template_name :: String.t()

  @doc """
  The configured name -> module map. Empty when the deployment registered none.
  """
  @spec templates() :: %{optional(template_name()) => module()}
  def templates do
    case Application.get_env(:raxol_console, :app_templates, %{}) do
      map when is_map(map) -> map
      list when is_list(list) -> Map.new(list)
      _ -> %{}
    end
  end

  @doc """
  Resolve a template name to its registered module.

  Fails closed on anything unregistered, including when nothing is registered.
  """
  @spec fetch(term()) :: {:ok, module()} | {:error, {:unknown_app_template, term()}}
  def fetch(name) when is_binary(name) do
    case Map.fetch(templates(), name) do
      {:ok, module} when is_atom(module) and not is_nil(module) -> {:ok, module}
      _ -> {:error, {:unknown_app_template, name}}
    end
  end

  def fetch(name), do: {:error, {:unknown_app_template, name}}
end
