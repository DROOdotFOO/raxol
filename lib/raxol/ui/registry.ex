defmodule Raxol.UI.Registry do
  @moduledoc """
  The authoritative list of Raxol's first-class UI components.

  ## What this IS

  One entry per component that is reachable as a **declaration type** -- an atom
  the layout engine dispatches on, that `Raxol.MCP.TreeWalker` can derive agent
  tools from, and that `Raxol.Core.Accessibility.Projection` can project into an
  accessibility node. Each entry records the type atom, the implementing module,
  a group (drawn from the `Raxol.Playground.Catalog` category vocabulary), which
  of the two cross-cutting behaviours the module actually implements, and the
  name of the Catalog demo that shows it off (`nil` where none exists yet).

  ## What this IS NOT

  It is not an index of every module under `Raxol.UI.*` -- there are ~94, and
  most are internal sub-modules of a component (`SelectList.Renderer`,
  `Table.State`) or non-declarative helpers with no type atom of their own. A
  registry that listed them would be noise: nothing dispatches on them, so
  nothing can drift from them.

  It is also not the playground catalog. `Raxol.Playground.Catalog` is a list of
  runnable *examples* (42 of them, keyed by demo module); several demos hand-roll
  their subject with the View DSL, and several components here have no demo at
  all. The `:demo` field is the join between the two, not a duplication.

  ## Why the package-side maps still exist

  `Raxol.MCP.TreeWalker` and `Raxol.Core.Accessibility.Projection` each carry
  their own `type -> module` map. They live in `raxol_mcp` and `raxol_core`,
  neither of which depends on main raxol, so they cannot read this module at
  compile time -- they cannot even name a component module without a
  `@compile {:no_warn_undefined, ...}` escape, and resolve modules at runtime
  behind a `function_exported?/3` guard. Deriving those maps from this registry
  would invert the dependency direction of the umbrella.

  The maps are therefore duplicated on purpose and kept honest by test:
  `Raxol.UI.RegistryConformanceTest` runs in the main app (where every component
  module is loaded) and fails when a map and this registry disagree, or when an
  entry claims a behaviour its module does not implement.
  """

  @type entry :: %{
          type: atom(),
          module: module(),
          group: atom(),
          mcp?: boolean(),
          a11y?: boolean(),
          demo: String.t() | nil
        }

  @entries [
    %{
      type: :button,
      module: Raxol.UI.Components.Input.Button,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "Button"
    },
    %{
      type: :text_input,
      module: Raxol.UI.Components.Input.TextInput,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "TextInput"
    },
    %{
      type: :text_area,
      module: Raxol.UI.Components.Input.TextArea,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "TextArea"
    },
    %{
      type: :password_field,
      module: Raxol.UI.Components.Input.PasswordField,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "PasswordField"
    },
    %{
      type: :select_list,
      module: Raxol.UI.Components.Input.SelectList,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "SelectList"
    },
    %{
      type: :checkbox,
      module: Raxol.UI.Components.Input.Checkbox,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "Checkbox"
    },
    %{
      type: :scrubber,
      module: Raxol.UI.Components.Input.Scrubber,
      group: :input,
      mcp?: true,
      a11y?: true,
      demo: "Scrubber"
    },
    %{
      type: :menu,
      module: Raxol.UI.Components.Input.Menu,
      group: :navigation,
      mcp?: true,
      a11y?: true,
      demo: "Menu"
    },
    %{
      type: :tabs,
      module: Raxol.UI.Components.Input.Tabs,
      group: :navigation,
      mcp?: true,
      a11y?: true,
      demo: "Tabs"
    },
    %{
      type: :modal,
      module: Raxol.UI.Components.Modal,
      group: :overlay,
      mcp?: true,
      a11y?: true,
      demo: "Modal"
    },
    %{
      type: :table,
      module: Raxol.UI.Components.Table,
      group: :display,
      mcp?: true,
      a11y?: true,
      demo: "Table"
    },
    %{
      type: :tree,
      module: Raxol.UI.Components.Display.Tree,
      group: :display,
      mcp?: true,
      a11y?: true,
      demo: "Tree"
    },
    # The "Container" demo deliberately windows with `Enum.slice/3` rather than
    # mounting this Component, so it does not demonstrate it.
    %{
      type: :viewport,
      module: Raxol.UI.Components.Display.Viewport,
      group: :display,
      mcp?: true,
      a11y?: true,
      demo: nil
    },
    %{
      type: :bar_chart,
      module: Raxol.UI.Charts.BarChart,
      group: :visualization,
      mcp?: true,
      a11y?: true,
      demo: "BarChart"
    },
    %{
      type: :line_chart,
      module: Raxol.UI.Charts.LineChart,
      group: :visualization,
      mcp?: true,
      a11y?: true,
      demo: "LineChart"
    },
    %{
      type: :scatter_chart,
      module: Raxol.UI.Charts.ScatterChart,
      group: :visualization,
      mcp?: true,
      a11y?: true,
      demo: "ScatterChart"
    }
  ]

  @by_type Map.new(@entries, &{&1.type, &1})
  @type_map Map.new(@entries, &{&1.type, &1.module})
  @types Enum.map(@entries, & &1.type)
  @mcp_types @entries |> Enum.filter(& &1.mcp?) |> Enum.map(& &1.type)
  @a11y_types @entries |> Enum.filter(& &1.a11y?) |> Enum.map(& &1.type)

  @doc "Every registered component, in registration order (grouped by `:group`)."
  @spec list() :: [entry()]
  def list, do: @entries

  @doc "The entry for a declaration type, or `nil`."
  @spec get(atom()) :: entry() | nil
  def get(type) when is_atom(type), do: Map.get(@by_type, type)
  def get(_type), do: nil

  @doc "Every registered declaration type."
  @spec types() :: [atom()]
  def types, do: @types

  @doc """
  The `%{type => module}` shape `Raxol.MCP.TreeWalker` and
  `Raxol.Core.Accessibility.Projection` take as a `:type_map` override.
  """
  @spec type_map() :: %{atom() => module()}
  def type_map, do: @type_map

  @doc "Types whose Component implements `Raxol.MCP.ToolProvider`."
  @spec mcp_types() :: [atom()]
  def mcp_types, do: @mcp_types

  @doc "Types whose Component implements `Raxol.Core.Accessibility.Provider`."
  @spec a11y_types() :: [atom()]
  def a11y_types, do: @a11y_types
end
