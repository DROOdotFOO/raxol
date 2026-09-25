defmodule Raxol.UI do
  @moduledoc """
  Internal multi-framework adapter layer.

  Most apps should use `use Raxol.Core.Runtime.Application` (TEA pattern).
  See the [Quickstart](docs/getting-started/QUICKSTART.md) for the recommended approach.

  This module provides an alternative adapter for advanced use cases where you need
  to mix Phoenix LiveView, HEEx, or raw terminal buffer access within a Raxol app.

  Supported adapters: `:react`, `:liveview`, `:heex`, `:universal`, `:raw`.
  """

  defmacro __using__(opts) do
    framework = Keyword.get(opts, :framework, :react)

    # Evaluate framework selection at macro expansion time,
    # not runtime, to avoid importing non-existent modules
    framework_code =
      case framework do
        :react ->
          quote(do: use(Raxol.Component))

        :svelte ->
          raise "Svelte framework has been removed. Please use :react, :liveview, :heex, :universal, or :raw instead"

        :liveview ->
          quote(do: use(Raxol.LiveView))

        :heex ->
          quote(do: use(Raxol.HEEx))

        :universal ->
          quote(do: use(Raxol.HEEx))

        :raw ->
          quote do
            import Raxol.Terminal.Buffer
            import Raxol.Terminal.Commands
          end

        _ ->
          raise ArgumentError, """
          Invalid framework: #{inspect(framework)}

          Supported frameworks:
          - :react (React-style components)
          - :liveview (Phoenix LiveView style)
          - :heex (Phoenix HEEx templates)
          - :universal (Universal HEEx templates)
          - :raw (Direct terminal buffer access)
          """
      end

    framework_code
  end

  @doc """
  Create a new UI component with the specified framework.
  """
  def create_component(module, framework, opts \\ []) do
    quote do
      defmodule unquote(module) do
        use Raxol.UI, framework: unquote(framework)
        unquote(opts[:body] || quote(do: nil))
      end
    end
  end
end
