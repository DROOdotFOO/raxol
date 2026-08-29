defmodule RaxolPlaygroundWeb.PlaygroundComponents do
  @moduledoc "Shared UI components for the Raxol playground."
  use Phoenix.Component

  alias RaxolPlaygroundWeb.Playground.Helpers

  @doc """
  The SSH-command callout that appears on landing twice: once in the hero,
  once in the deep dive. Each needs its own DOM id because the hook attaches
  per element.
  """
  attr(:id, :string, required: true)
  attr(:cmd, :string, required: true)

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
      <span class="prompt">$ </span><%= @cmd %><span class="cursor-blink text-axol-coral">_</span>
      <span class="sr-only" data-copy-status aria-live="polite"></span>
    </button>
    """
  end

  @doc """
  Pearl-bg + dark-overlay layered backdrop, used as the bottom layer of
  the landing, gallery, and demo pages. Pass `orbs={true}` to add the
  three floating accent orbs (currently used only by landing).
  """
  attr(:orbs, :boolean, default: false)

  def atmosphere(assigns) do
    ~H"""
    <div class="atmosphere" aria-hidden="true">
      <div class="pearl-bg"></div>
      <div class="dark-overlay"></div>
      <%= if @orbs do %>
        <div class="orb orb-1"></div>
        <div class="orb orb-2"></div>
        <div class="orb orb-3"></div>
      <% end %>
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
      <span class="text-pearl-50">
        <%= if @variant == :banner do %>
          Try the real terminal experience:
        <% else %>
          Try the real terminal:
        <% end %>
      </span>
      <span class="text-axol-coral ml-2"><%= @ssh_cmd %></span>
      <span class="text-pearl-25 mx-2">|</span>
      <span class="text-sky">mix raxol.playground</span>
    </div>
    """
  end

  attr(:description, :string, default: nil)

  def terminal_fallback(assigns) do
    ~H"""
    <div class="py-8 text-center font-mono text-pearl-40">
      <%= if @description do %>
        <p class="mb-2 text-pearl-50"><%= @description %></p>
      <% end %>
      <p class="mb-4">For the full interactive experience:</p>
      <p class="text-sky">$ mix raxol.playground</p>
      <p class="mt-1 text-axol-coral">$ <%= Helpers.ssh_command() %></p>
    </div>
    """
  end

  attr(:show, :boolean, required: true)
  attr(:code, :string, default: "")

  def code_panel(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="w-full lg:w-1/3 border-t lg:border-t-0 border-subtle flex flex-col max-h-64 lg:max-h-none bg-obsidian-85">
        <div class="px-4 py-2 text-sm font-mono font-medium text-pearl-60 bg-panel-strong border-b border-subtle">
          Code Snippet
        </div>
        <div class="flex-1 overflow-auto p-4">
          <pre class="font-mono text-sm whitespace-pre-wrap text-sky"><%= String.trim(@code) %></pre>
        </div>
      </div>
    <% end %>
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
    <div class="terminal-chrome copyable-command relative group">
      <div class="terminal-chrome-body copyable-command__body flex items-center justify-between">
        <div>
          <span class="text-pearl-60">$</span>
          <span class={["ml-2", command_tone_class(@tone)]}><%= @command %></span>
          <%= if @comment do %>
            <span class="text-pearl-60 ml-4"># <%= @comment %></span>
          <% end %>
        </div>
        <button
          id={@id}
          phx-hook="CopyToClipboard"
          data-copy={@command}
          class="copy-chip opacity-0 group-hover:opacity-100 focus-visible:opacity-100 transition-opacity"
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
