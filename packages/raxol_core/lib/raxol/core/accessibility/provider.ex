defmodule Raxol.Core.Accessibility.Provider do
  @moduledoc """
  Behaviour a Component implements to describe itself to assistive technology.

  Parallels `Raxol.MCP.ToolProvider`: the callback receives the Component's
  declaration Element (the same map `mcp_tools/1` receives) and returns an
  accessibility node. `Raxol.Core.Accessibility.Projection` walks the Element
  tree and calls this callback for Components that implement it, falling back to
  a default role/label extraction otherwise.

  A Component knows where its own fields live (field locations are heterogeneous
  across the codebase), so co-locating the extractor here keeps each Component
  authoritative about its own shape.

  ## Returning children

  Omit `:children` for leaf Components (Button, TextInput, Checkbox) -- the
  projection recurses the Element's own children. Set `:children` only when the
  Component *synthesizes* semantic children not present as Element children
  (e.g. SelectList options built from an `:options` attr, Tabs, Table rows).

  ## Example

      @impl Raxol.Core.Accessibility.Provider
      def a11y_node(node) do
        %{role: :checkbox, label: node[:label], id: node[:id],
          state: %{checked?: node[:checked] || false}}
      end
  """

  @doc """
  Builds an accessibility node from a Component's declaration Element.

  Returned maps are normalized by `Raxol.Core.Accessibility.Projection`:
  missing keys are filled (`role` -> `:generic`, `state` -> `%{}`, `live?`
  derived from the role), so a Provider only needs to supply what it knows.
  """
  @callback a11y_node(element :: map()) ::
              Raxol.Core.Accessibility.Projection.accessibility_node()

  @doc """
  Returns true when `module` implements this behaviour.

  Guarded with `Code.ensure_loaded?/1` so raxol_core can dispatch to Component
  modules that live in main raxol (loaded only when main is present) without a
  compile-time dependency.
  """
  @spec provider?(module()) :: boolean()
  def provider?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :a11y_node, 1)
  end

  def provider?(_module), do: false
end
