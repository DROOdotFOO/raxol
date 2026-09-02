defmodule RaxolPlaygroundWeb.PlaygroundComponents do
  @moduledoc "Shared UI components for the Raxol playground."
  use Phoenix.Component

  alias RaxolPlaygroundWeb.Playground.Helpers

  @doc """
  The copy-to-clipboard command callout used across the landing page. Each
  caller needs its own DOM id because the hook attaches per element. Set
  `prompt: nil` for content that is not a shell command (a mix.exs dep).
  """
  attr(:id, :string, required: true)
  attr(:cmd, :string, required: true)
  attr(:prompt, :any, default: "$ ")

  def ssh_copy_block(assigns) do
    ~H"""
    <button
      type="button"
      class="ssh-hero"
      id={@id}
      phx-hook="CopyToClipboard"
      data-copy={@cmd}
      aria-label={"Copy command: #{@cmd}"}
    >
      <span :if={@prompt} class="prompt"><%= @prompt %></span><%= @cmd %><span class="cursor-blink text-axol-coral">_</span>
      <span class="sr-only" data-copy-status aria-live="polite"></span>
    </button>
    """
  end

  @doc """
  Pearl-bg + dark-overlay layered backdrop, the bottom layer of the landing,
  gallery, and demo pages.

  It used to take `orbs={true}` for three blurred floating accent discs. No
  caller ever passed it -- the docstring claimed the landing did, which stopped
  being true when the landing became the one-screen layout -- so the branch,
  the `.orb` rules and the `floatOrb` keyframes were all warming a decoration
  the site does not render.
  """
  def atmosphere(assigns) do
    ~H"""
    <div class="atmosphere" aria-hidden="true">
      <div class="pearl-bg"></div>
      <div class="dark-overlay"></div>
    </div>
    """
  end

  @doc """
  Terminal chrome bar. Drops the fake mac-style red/yellow/green dots in
  favor of one piece of information that earns its place: a shell-prompt
  prefix that signals "this is something runnable" and the title (treated
  as a filename or command).
  """
  attr(:title, :string, required: true)

  def terminal_chrome(assigns) do
    ~H"""
    <div class="terminal-chrome-bar">
      <span class="terminal-chrome-prompt" aria-hidden="true">$</span>
      <span class="terminal-chrome-title"><%= @title %></span>
    </div>
    """
  end

  attr(:variant, :atom, default: :banner)
  attr(:class, :string, default: "")

  def ssh_callout(assigns) do
    assigns = Phoenix.Component.assign(assigns, :ssh_cmd, Helpers.ssh_command())

    ~H"""
    <div class={[
      "font-mono text-sm",
      @variant == :banner && "panel p-4",
      @variant == :footer && "px-6 py-3 bg-panel border-t border-subtle",
      @class
    ]}>
      <span class="text-pearl-60">
        <%= if @variant == :banner do %>
          Try the real terminal experience:
        <% else %>
          Try the real terminal:
        <% end %>
      </span>
      <%= if @ssh_cmd do %>
        <span class="text-axol-coral ml-2"><%= @ssh_cmd %></span>
        <span class="text-pearl-60 mx-2">|</span>
      <% end %>
      <span class={["text-sky", is_nil(@ssh_cmd) && "ml-2"]}>mix raxol.playground</span>
    </div>
    """
  end

  attr(:description, :string, default: nil)

  def terminal_fallback(assigns) do
    ~H"""
    <div class="py-8 text-center font-mono text-pearl-60">
      <%!-- The description leads, so it takes the brighter tier. It used to be
           the dimmer of the two (50 over a 40 body); both were under the
           contrast floor, and raising them to it collapsed the tiers, so the
           hierarchy is restored upward rather than downward. --%>
      <%= if @description do %>
        <p class="mb-2 text-pearl-80"><%= @description %></p>
      <% end %>
      <p class="mb-4">For the full interactive experience:</p>
      <p class="text-sky">$ mix raxol.playground</p>
      <%= if ssh = Helpers.ssh_command() do %>
        <p class="mt-1 text-axol-coral">$ <%= ssh %></p>
      <% end %>
    </div>
    """
  end

  attr(:theme, :atom, required: true)
  attr(:themes, :list, required: true)
  attr(:form_id, :string, required: true)
  attr(:class, :string, default: "")

  def theme_selector(assigns) do
    ~H"""
    <form phx-change="select_theme" id={@form_id} class={@class}>
      <select
        name="theme"
        aria-label="Terminal color theme"
        class="font-mono px-3 py-1 text-sm rounded bg-panel border border-subtle text-pearl"
      >
        <%= for {key, label, _bg} <- @themes do %>
          <option value={key} selected={@theme == key}><%= label %></option>
        <% end %>
      </select>
    </form>
    """
  end

  attr(:level, :atom, required: true)

  def complexity_badge(assigns) do
    ~H"""
    <span class={"badge #{complexity_badge_variant(@level)}"}>
      <%= Helpers.complexity_label(@level) %>
    </span>
    """
  end

  @doc "Copyable command block with click-to-copy button."
  attr(:command, :string, required: true)
  attr(:comment, :string, default: nil)
  attr(:tone, :atom, values: [:coral, :sky], default: :coral)
  attr(:id, :string, required: true)

  def copyable_command(assigns) do
    ~H"""
    <div class="terminal-chrome copyable-command relative">
      <div class="terminal-chrome-body copyable-command__body">
        <%!-- The command scrolls sideways rather than wrapping. It is a string
             the reader runs, not prose: wrapped, it breaks at whatever
             character the width lands on, so a phone got `install |` and
             `bash` on separate rows of something that has to be one line. --%>
        <div class="copyable-command__cmd">
          <span class="text-pearl-60">$</span>
          <span class={["ml-2", command_tone_class(@tone)]}><%= @command %></span>
          <%= if @comment do %>
            <span class="text-pearl-60 ml-4"># <%= @comment %></span>
          <% end %>
        </div>
        <%!-- Reveal is CSS, scoped to `.copyable-command`, so a touch screen
             can be given the button outright. It used to carry Tailwind's
             `opacity-0 group-hover:opacity-100`, which has no hover to fire on
             a phone: the one action the landing page has was invisible there,
             while staying in the tab order and hit-testable. --%>
        <button
          id={@id}
          phx-hook="CopyToClipboard"
          data-copy={@command}
          class="copy-chip"
          aria-label={"Copy command: #{@command}"}
        >
          copy
        </button>
      </div>
    </div>
    """
  end

  defp command_tone_class(:coral), do: "text-axol-coral"
  defp command_tone_class(:sky), do: "text-sky"

  defp complexity_badge_variant(:basic), do: "badge--sky"
  defp complexity_badge_variant(:intermediate), do: "badge--gold"
  defp complexity_badge_variant(:advanced), do: ""
  defp complexity_badge_variant(_), do: "badge--gold"
end
