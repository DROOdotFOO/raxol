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

  @typedoc """
  What a Provider returns: a partial node. Every key is optional.

  `Projection.finalize/3` reads each field with a default (`role` ->
  `Roles.default_role/0`, `state` -> `%{}`, `live?` -> `Roles.live?/1`, `label`
  and `value` -> `nil`) and supplies `:id` itself from the Element, so a
  Provider supplies only what it knows.

  This is deliberately NOT `Projection.accessibility_node()`. That type is the
  *normalized* node -- all seven keys present -- and declaring it as the
  callback's return made all 16 conforming Components a dialyzer
  `callback_type_mismatch`, because none of them returns all seven.

  `label`, `value`, `id` and the `state` values are `term()` rather than
  narrower types on purpose: Providers read their fields out of a declaration
  Element with `node[:key]` / `attrs[:key]`, which is `term()`, and pass the
  result straight through (e.g. `label: node[:aria_label] || node[:label]`,
  `state: %{variant: attrs[:role]}`). `Projection.normalize_label/1` and
  `compact_state/1` are what actually constrain them downstream.
  """
  @type provided_node :: %{
          optional(:role) => atom(),
          optional(:label) => term(),
          optional(:state) => %{optional(atom()) => term()},
          optional(:value) => term(),
          optional(:live?) => boolean(),
          optional(:children) => [provided_node()],
          optional(:id) => term()
        }

  @doc """
  Builds an accessibility node from a Component's declaration Element.

  Returned maps are normalized by `Raxol.Core.Accessibility.Projection`:
  missing keys are filled (`role` -> `:generic`, `state` -> `%{}`, `live?`
  derived from the role), so a Provider only needs to supply what it knows.
  """
  @callback a11y_node(element :: map()) :: provided_node()

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
