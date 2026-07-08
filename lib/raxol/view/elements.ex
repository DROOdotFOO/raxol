defmodule Raxol.View.Elements do
  @moduledoc """
  Backward-compatibility shim for view elements.

  All functions and macros delegate to `Raxol.Core.Renderer.View`, which is
  the canonical View DSL. Prefer importing View directly in new code.
  """

  alias Raxol.Core.Renderer.View

  # --- Macros (forward to View) ---


  defmacro row(opts, do: block) do
    quote do
      require Raxol.Core.Renderer.View
      Raxol.Core.Renderer.View.row(unquote(opts), do: unquote(block))
    end
  end

  defmacro box(opts, do: block) do
    quote do
      require Raxol.Core.Renderer.View
      Raxol.Core.Renderer.View.box(unquote(opts), do: unquote(block))
    end
  end

  defmacro column(opts, do: block) do
    quote do
      require Raxol.Core.Renderer.View
      Raxol.Core.Renderer.View.column(unquote(opts), do: unquote(block))
    end
  end

  # --- Functions (delegate to View) ---

  def row(opts \\ []), do: View.row(opts)
  def box(opts \\ []), do: View.box(opts)
  def column(opts \\ []), do: View.column(opts)
  def text(content, opts \\ []), do: View.text(content, opts)
  def button(text, opts \\ []), do: View.button(text, opts)
  def checkbox(label, opts \\ []), do: View.checkbox(label, opts)
  def text_input(opts \\ []), do: View.text_input(opts)
  def table(opts \\ []), do: View.table(opts)
  def label(opts \\ []), do: View.label(opts)
  def panel(opts \\ []), do: View.panel(opts)
  def border(view, opts \\ []), do: View.border(view, opts)
  def scroll(view, opts \\ []), do: View.scroll(view, opts)
  def flex(constraints), do: View.flex(constraints)
  def shadow(opts \\ []), do: View.shadow(opts)
end
