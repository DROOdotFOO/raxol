defmodule Raxol.Core.Accessibility.Roles do
  @moduledoc """
  The ARIA role vocabulary for the accessibility tree.

  Maps a declaration Element `:type` to a standard ARIA role and answers which
  roles are live regions. This is the single source of truth for the default
  `type -> role` mapping; Components that implement
  `Raxol.Core.Accessibility.Provider` may override the role for their own node,
  but the values here are the vocabulary they should draw from.

  Interactive and structural Components map to standard ARIA roles. Tables map
  to `:grid` (arrow-navigable, focusable cells) rather than the static `:table`.
  Layout containers map to `:group`; bare text maps to `:text`. Unknown types
  fall back to `:generic` so the projection is total.
  """

  # Declaration Element type -> ARIA role. Provider Components plus the DSL
  # primitives the projection may encounter when no Provider is present.
  @type_role %{
    # interactive Components
    button: :button,
    text_input: :textbox,
    text_area: :textbox,
    textarea: :textbox,
    password_field: :textbox,
    multi_line_input: :textbox,
    select_list: :listbox,
    checkbox: :checkbox,
    radio: :radio,
    radio_group: :radiogroup,
    menu: :menu,
    tabs: :tablist,
    modal: :dialog,
    # structural Components
    table: :grid,
    tree: :tree,
    viewport: :region,
    progress: :progressbar,
    # charts render as a single labeled image
    bar_chart: :img,
    line_chart: :img,
    scatter_chart: :img,
    heatmap: :img,
    # layout primitives
    row: :group,
    column: :group,
    box: :group,
    panel: :group,
    container: :group,
    flex: :group,
    grid: :group,
    # text primitives + live announcers
    text: :text,
    label: :text,
    alert: :alert,
    status: :status,
    log: :log
  }

  # Role a container's semantic children should carry. Convenience for Provider
  # impls that synthesize children (e.g. SelectList options); the projection
  # does not apply these automatically.
  @child_role %{
    listbox: :option,
    menu: :menuitem,
    tablist: :tab,
    grid: :row,
    tree: :treeitem,
    radiogroup: :radio
  }

  @live_roles [:alert, :status, :log, :progressbar]

  @default_role :generic

  @doc "The ARIA role for a declaration Element type. Unknown types -> `:generic`."
  @spec role_for(term()) :: atom()
  def role_for(type) when is_atom(type), do: Map.get(@type_role, type, @default_role)
  def role_for(_type), do: @default_role

  @doc "The conventional child role for a container role, or `nil`."
  @spec child_role(atom()) :: atom() | nil
  def child_role(role) when is_atom(role), do: Map.get(@child_role, role)
  def child_role(_role), do: nil

  @doc "Whether a role denotes a live region (announced as it changes)."
  @spec live?(atom()) :: boolean()
  def live?(role), do: role in @live_roles

  @doc "The fallback role for Elements with no mapping."
  @spec default_role() :: atom()
  def default_role, do: @default_role
end
