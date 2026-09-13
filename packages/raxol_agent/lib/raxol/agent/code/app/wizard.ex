defmodule Raxol.Agent.Code.App.Wizard do
  @moduledoc """
  Onboarding wizard for `Raxol.Agent.Code.App`: the overlay that owns the
  keyboard while a provider is being connected.

  Every function takes and returns the App model, so the TEA contract is
  unchanged -- `App.update/2` routes keys here and folds the result. Three
  responsibilities:

    * **Selectable steps** (`:browse`, `:models`, `:sessions`) -- arrow keys
      move a cursor, Enter picks. `App.update/2` keeps ownership of those keys
      because a typed prompt or slash command still takes precedence.
    * **Modal steps** (`:credential`, `:confirm_save`) -- masked key entry and
      the save-to-1Password prompt. These OWN the keyboard: `handle_wizard/2`
      sees every normalized event, so half-typed secret input is never
      discarded by a stray shortcut (`modal_wizard?/1` is the test).
    * **Rendering** -- `panel/1` draws the active step's overlay and
      `hint_panel/1` the "no provider connected" panel.
  """

  import Raxol.Core.Renderer.View, except: [view: 1]

  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Code.App.Commands
  alias Raxol.UI.Harness.InputEvent

  # -- wizard steps -----------------------------------------------------------

  @doc false
  def modal_wizard?(%{wizard: %{step: step}})
      when step in [:credential, :confirm_save], do: true

  def modal_wizard?(_model), do: false

  @doc false
  def open_browse(model) do
    entries = browse_entries()
    cursor = default_cursor(entries)

    %{
      model
      | wizard: %{step: :browse, cursor: cursor, entries: entries},
        notice: nil
    }
  end

  # Provider rows for the list, carrying the diagnostics so the panel can show
  # availability + an actionable note per provider.
  defp browse_entries, do: Raxol.Agent.Backend.Resolver.diagnostics().providers

  # Start the cursor on the first available provider, else the top.
  defp default_cursor(entries) do
    case Enum.find_index(entries, & &1.available?) do
      nil -> 0
      idx -> idx
    end
  end

  @doc false
  def wizard_move(
        %{wizard: %{entries: entries, cursor: cursor} = wizard} = model,
        delta
      ) do
    max = max(length(entries) - 1, 0)
    next = min(max, max(0, cursor + delta))
    %{model | wizard: %{wizard | cursor: next}}
  end

  @doc false
  def maybe_wizard_select(%{wizard: %{step: :browse, entries: entries, cursor: cursor}} = model) do
    case Enum.at(entries, cursor) do
      nil -> model
      entry -> select_provider(model, entry.harness, entry.keyless?)
    end
  end

  def maybe_wizard_select(%{wizard: %{step: :sessions, entries: entries, cursor: cursor}} = model) do
    case Enum.at(entries, cursor) do
      nil -> model
      entry -> Commands.switch_session(%{model | wizard: nil}, entry.id)
    end
  end

  def maybe_wizard_select(%{wizard: %{step: :models, entries: entries, cursor: cursor}} = model) do
    case Enum.at(entries, cursor) do
      nil ->
        model

      entry ->
        App.notice(
          %{model | model_override: entry.model, wizard: nil},
          "model set to #{entry.model}"
        )
    end
  end

  def maybe_wizard_select(model), do: model

  # A keyless provider connects immediately; a keyed one opens masked entry.
  defp select_provider(model, harness, true) do
    model |> Commands.connect(harness, nil, nil) |> close_wizard_if_ready()
  end

  defp select_provider(model, harness, false) do
    %{
      model
      | wizard: %{step: :credential, harness: harness, buffer: ""},
        notice:
          "#{harness}: paste an op:// reference (saved) or an API key (Enter to submit, Esc to cancel)"
    }
  end

  @doc false
  def close_wizard(model), do: %{model | wizard: nil}

  defp close_wizard_if_ready(model) do
    if App.provider_ready?(model), do: close_wizard(model), else: model
  end

  # -- modal steps (own the keyboard) -----------------------------------------

  @doc false
  def handle_wizard(norm, %{wizard: %{step: :credential}} = model) do
    cond do
      InputEvent.text?(norm) ->
        {append_credential(model, InputEvent.printable_char(norm)), []}

      InputEvent.key(norm) == :enter ->
        {submit_credential(model), []}

      InputEvent.key(norm) == :backspace ->
        {backspace_credential(model), []}

      InputEvent.key(norm) == :escape ->
        {open_browse(model), []}

      true ->
        {model, []}
    end
  end

  def handle_wizard(norm, %{wizard: %{step: :confirm_save}} = model) do
    cond do
      InputEvent.printable_char(norm) in ["y", "Y"] ->
        {save_key_to_op(model), []}

      InputEvent.printable_char(norm) in ["n", "N"] ->
        {decline_save(model), []}

      InputEvent.key(norm) == :escape ->
        {decline_save(model), []}

      true ->
        {model, []}
    end
  end

  defp append_credential(%{wizard: wizard} = model, char),
    do: %{model | wizard: %{wizard | buffer: wizard.buffer <> char}}

  defp backspace_credential(%{wizard: %{buffer: buffer} = wizard} = model),
    do: %{model | wizard: %{wizard | buffer: String.slice(buffer, 0..-2//1)}}

  # An op:// reference stores + connects; a raw key connects for this session
  # and (if op is available) offers to save it to 1Password.
  defp submit_credential(%{wizard: %{harness: harness, buffer: buffer}} = model) do
    trimmed = String.trim(buffer)

    cond do
      trimmed == "" ->
        model

      String.starts_with?(trimmed, "op://") ->
        model |> Commands.connect(harness, trimmed, nil) |> close_wizard_if_ready()

      true ->
        model
        |> Commands.connect(harness, trimmed, nil)
        |> maybe_offer_save(harness, trimmed)
    end
  end

  defp maybe_offer_save(model, harness, key) do
    if Raxol.Agent.Backend.Credentials.op_available?() do
      %{
        model
        | wizard: %{step: :confirm_save, harness: harness, key: key},
          notice: "Save this #{harness} key to 1Password?  [y] yes   [n] keep for this session"
      }
    else
      close_wizard(model)
    end
  end

  defp save_key_to_op(%{wizard: %{harness: harness, key: key}} = model) do
    case model.op_saver.(harness, key) do
      {:ok, ref} ->
        _ = Raxol.Agent.Backend.Credentials.put(harness, op_ref: ref)

        model
        |> close_wizard()
        |> App.notice("saved #{harness} key to 1Password (#{ref})")

      {:error, reason} ->
        model
        |> close_wizard()
        |> App.notice(
          "could not save to 1Password: #{inspect(reason)} — key kept for this session"
        )
    end
  end

  defp decline_save(%{wizard: %{harness: harness}} = model),
    do:
      model
      |> close_wizard()
      |> App.notice("#{harness} key kept for this session only")

  @doc false
  def default_op_saver(harness, key),
    do: Raxol.Agent.Backend.Credentials.create_item(harness, key)

  # -- provider hints ---------------------------------------------------------

  @doc false
  def login_status_text do
    rows =
      Raxol.Agent.Backend.Resolver.status()
      |> Enum.map_join("\n", fn s ->
        mark = if s.available?, do: "●", else: "○"
        src = if s.source, do: " (#{s.source})", else: ""
        "  #{mark} #{s.harness}#{src}"
      end)

    """
    Connect a provider with /login:
      /login anthropic op://Vault/Anthropic/key   1Password reference (persisted)
      /login openai sk-...                         session key (not saved)
      /login openrouter browser                    sign in via browser (persisted)
      /login lm_studio                             local server (no key)

    ● connected  ○ not connected
    #{rows}
    """
    |> String.trim_trailing()
  end

  @doc false
  # Shown on the setup panel and as the hint when a prompt is sent with no
  # provider connected.
  def provider_setup_hint(%{provider_status: {:no_key, harness}}) do
    "harness #{harness} was selected but no key resolved.\n\n" <>
      login_status_text()
  end

  def provider_setup_hint(_model) do
    "No LLM provider connected.\n\n" <> login_status_text()
  end

  # -- panels -----------------------------------------------------------------

  @doc false
  # The active step's overlay. `App.view/1` decides WHEN a panel shows; the
  # step decides WHICH one, so a new step adds one clause here and nowhere in
  # the view.
  def panel(%{step: :browse} = wizard), do: browse_panel(wizard)
  def panel(%{step: :credential} = wizard), do: credential_panel(wizard)
  def panel(%{step: :confirm_save} = wizard), do: confirm_save_panel(wizard)
  def panel(%{step: :sessions} = wizard), do: sessions_panel(wizard)
  def panel(%{step: :models} = wizard), do: models_panel(wizard)

  defp models_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> model_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("pick a model  (↑↓ move · Enter select · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
  end

  defp model_row(entry, selected?) do
    marker = if selected?, do: "▸", else: " "
    fg = if selected?, do: :cyan, else: :white
    style = if selected?, do: [:bold], else: []
    text("#{marker} #{entry.label}", fg: fg, style: style)
  end

  defp sessions_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> model_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("resume a session  (↑↓ move · Enter resume · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
  end

  defp browse_panel(%{entries: entries, cursor: cursor}) do
    rows =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> provider_row(entry, index == cursor) end)

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("connect a provider  (↑↓ move · Enter connect · Esc cancel)",
            fg: :yellow,
            style: [:bold]
          )
        ] ++ rows
      end
    end
  end

  defp provider_row(entry, selected?) do
    marker = if selected?, do: "▸", else: " "
    avail = if entry.available?, do: "●", else: "○"
    note = if entry.note, do: "  #{entry.note}", else: ""
    fg = if selected?, do: :cyan, else: :white
    style = if selected?, do: [:bold], else: []
    text("#{marker} #{avail} #{entry.label}#{note}", fg: fg, style: style)
  end

  defp credential_panel(%{harness: harness, buffer: buffer}) do
    shown =
      if String.starts_with?(buffer, "op://"),
        do: buffer,
        else: String.duplicate("•", String.length(buffer))

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [
          text("connect #{harness}", fg: :yellow, style: [:bold]),
          text("credential: #{shown}▌", fg: :cyan),
          text("op:// reference is stored; a raw key can be saved to 1Password",
            style: [:dim]
          )
        ]
      end
    end
  end

  defp confirm_save_panel(%{harness: harness}) do
    box style: %{border: :single, padding: 0} do
      text(
        "Save #{harness} key to 1Password?  [y] yes   [n] keep for this session",
        fg: :yellow
      )
    end
  end

  @doc false
  def hint_panel(model) do
    lines = String.split(provider_setup_hint(model), "\n")

    box style: %{border: :single, padding: 0} do
      column style: %{gap: 0} do
        [text("connect a provider to begin", fg: :yellow, style: [:bold])] ++
          Enum.map(lines, &text(&1, fg: :cyan))
      end
    end
  end
end
