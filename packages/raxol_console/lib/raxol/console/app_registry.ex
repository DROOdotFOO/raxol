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

  A keyword list resolves the same way, since that is the ordinary shape for
  Elixir config: `[dashboard: MyConsole.Apps.Dashboard]`.

  ## A registration is checked, not merely recorded

  Being an atom is not evidence of being a bookable app, so `fetch/1` also
  requires the module to LOAD and to export the TEA callbacks it will be driven
  by. Deferring those checks to first use would mean a deployment that boots
  green and then drops every chat: `Raxol.Console.RuntimeConfig.build/2` resolves
  the name at boot, but nothing tries to START the app until a real chat arrives,
  and by then the failure is a dead session behind a `Raxol.Gateway.SessionRouter`
  that has already answered `:ok`. A typo in this map is a config error, and a
  config error belongs at boot.

  See `Raxol.Console.RuntimeConfig.handler_spec/2` for what a resolved module is
  then booted into, and GitHub #763 for why the package format does not carry a
  TEA app of its own.
  """

  # The minimum a `Raxol.Core.Runtime.Application` must export to be driven by
  # `Raxol.Gateway.Handler.Lifecycle`: the model, the fold, and the frame.
  # `subscriptions/1` is deliberately not required -- the Lifecycle tolerates its
  # absence, and demanding it would reject an otherwise working app.
  @tea_callbacks [init: 1, update: 2, view: 1]

  @type template_name :: String.t()

  @typedoc "Why a registered name could not be resolved to a bookable app."
  @type invalid_reason :: :module_not_loaded | {:missing_callbacks, keyword(arity())}

  @doc """
  The configured name -> module map. Empty when the deployment registered none.

  Total: a malformed entry is dropped rather than raised on, so a bad config
  shape surfaces through `fetch/1` as `{:unknown_app_template, name}` at boot
  instead of as an `ArgumentError` from inside config reading.
  """
  @spec templates() :: %{optional(template_name()) => module()}
  def templates do
    :raxol_console
    |> Application.get_env(:app_templates, %{})
    |> normalize()
  end

  @doc """
  Resolve a template name to its registered module.

  Fails closed on anything unregistered, including when nothing is registered,
  and on a registered name whose module cannot serve as a TEA app.
  """
  @spec fetch(term()) ::
          {:ok, module()}
          | {:error, {:unknown_app_template, term()}}
          | {:error, {:invalid_app_template, template_name(), module(), invalid_reason()}}
  def fetch(name) when is_binary(name) do
    case Map.fetch(templates(), name) do
      {:ok, module} -> validate(name, module)
      :error -> {:error, {:unknown_app_template, name}}
    end
  end

  def fetch(name), do: {:error, {:unknown_app_template, name}}

  # -- private ---------------------------------------------------------------

  defp normalize(entries) when is_map(entries) or is_list(entries),
    do: entries |> Enum.flat_map(&entry/1) |> Map.new()

  defp normalize(_), do: %{}

  defp entry({name, module}) when is_binary(name) and is_atom(module) and not is_nil(module),
    do: [{name, module}]

  defp entry({name, module}) when is_atom(name) and not is_nil(name),
    do: entry({Atom.to_string(name), module})

  defp entry(_), do: []

  defp validate(name, module) do
    with :ok <- ensure_loaded(name, module), do: ensure_tea_app(name, module)
  end

  defp ensure_loaded(name, module) do
    if Code.ensure_loaded?(module),
      do: :ok,
      else: {:error, {:invalid_app_template, name, module, :module_not_loaded}}
  end

  defp ensure_tea_app(name, module) do
    case Enum.reject(@tea_callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end) do
      [] -> {:ok, module}
      missing -> {:error, {:invalid_app_template, name, module, {:missing_callbacks, missing}}}
    end
  end
end
