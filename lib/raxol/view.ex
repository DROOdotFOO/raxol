defmodule Raxol.View do
  @moduledoc """
  Main view module for Raxol.

  `use Raxol.View` imports the full View DSL from `Raxol.Core.Renderer.View`.

  Also provides the `~V` sigil for template-based view definitions (experimental).
  """

  @doc """
  Sigil for creating Raxol views with template syntax (experimental).
  """
  defmacro sigil_V(expr, opts) do
    case expr do
      {_, _, [template]} when is_binary(template) ->
        quote do
          Raxol.View.parse_template(unquote(template), unquote(opts))
        end

      _ ->
        quote do
          _ = unquote(expr)
          nil
        end
    end
  end

  @doc false
  def parse_template(template, _opts \\ []) do
    %{
      type: :view,
      template: template,
      parsed_at: DateTime.utc_now()
    }
  end

  defmacro __using__(_opts) do
    quote do
      import Raxol.Core.Renderer.View, except: [view: 1, children_from_block: 1]
    end
  end
end
