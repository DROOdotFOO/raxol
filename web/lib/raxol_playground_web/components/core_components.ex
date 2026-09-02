defmodule RaxolPlaygroundWeb.CoreComponents do
  @moduledoc """
  Flash notifications and the JS show/hide helpers that drive them.

  The Phoenix generator originally shipped modal, form, table, button,
  and icon helpers here. None were used by the playground (every gen
  template that referenced them was an unconfigured Phoenix scaffold),
  so they were removed. The synthwave playground uses its own
  `PlaygroundComponents`, `landing_live`, and the CSS classes in
  `app.css` instead.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages to display")
  attr(:title, :string, default: nil)

  attr(:kind, :atom,
    values: [:info, :error],
    doc: "used for styling and flash lookup"
  )

  attr(:rest, :global,
    doc: "the arbitrary HTML attributes to add to the flash container"
  )

  slot(:inner_block,
    doc: "the optional inner block that renders the flash message"
  )

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-5 right-5 z-50 panel p-3 font-mono shadow-panel cursor-pointer",
        @kind == :info && "text-sky border border-subtle",
        @kind == :error && "text-coral-red border border-subtle"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <%= @title %>
      </p>
      <p class="mt-2 text-sm leading-5"><%= msg %></p>
      <button type="button" class="absolute top-1 right-1 p-2 text-pearl-60 hover:text-pearl" aria-label="close">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:id, :string,
    default: "flash-group",
    doc: "the optional id of flash container"
  )

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title="Success" flash={@flash} />
      <.flash kind={:error} title="Error" flash={@flash} />
      <.flash
        id="client-info"
        kind={:info}
        title="Success"
        phx-mounted={show("#client-info")}
        phx-hook="Flash"
        hidden
      />
      <.flash
        id="client-error"
        kind={:error}
        title="Error"
        phx-mounted={show("#client-error")}
        phx-hook="Flash"
        hidden
      />
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
