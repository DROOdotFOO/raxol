defmodule Raxol.UI.Harness.CommandRegistry do
  @moduledoc """
  The harness slash-command vocabulary — ONE registry, three inlets.

  Keys (`Raxol.UI.Harness.Keymap` chords), the command palette (browse),
  and slash commands (typed) are three ways into the SAME command
  vocabulary: `Raxol.Harness.HarnessApp.Model.dispatch_command/2`'s
  `%{type:, payload:}` maps. This module is the typed inlet's source of
  truth: what commands exist, what they claim to do, and how each one
  runs — so `/help`, the autocomplete popup, and the executed behavior
  can never drift from each other.

  ## Entry shape

  Every entry is pure data; the HOST interprets `:run` (the registry
  never touches a model):

    * `{:dispatch, command}` — feed the existing
      `Model.dispatch_command/2` vocabulary verbatim. The dispatch layer
      already owns the honesty rules (approval refusals, lane stubs), so
      a slash inlet inherits them for free.
    * an atom (`:help` / `:session` / `:steer` / `:quit`) — a host-level
      action that needs model context the registry cannot know.

  `args: :text` marks a command whose remainder is meaningful
  (`/steer make it shorter`); `:none` commands ignore any remainder.

  ## Matching contract

  `match/1` is a PREFIX match on the name, sorted by name — the
  autocomplete popup renders exactly this list, so what is shown is
  provably what `run/1` would find (never a second, drifting filter).
  """

  @type run ::
          {:dispatch, map()}
          | :help
          | :session
          | :steer
          | :quit

  @type entry :: %{
          name: String.t(),
          args: :none | :text,
          description: String.t(),
          run: run()
        }

  # Sorted by name — match/1 preserves this order, so the popup's order
  # is stable and alphabetical by construction.
  @entries [
    %{
      name: "approve",
      args: :none,
      description: "allow the live approval (same as y)",
      run: {:dispatch, %{type: :approval_answer, payload: %{answer: :allow}}}
    },
    %{
      name: "deny",
      args: :none,
      description: "reject the live approval (same as n)",
      run: {:dispatch, %{type: :approval_answer, payload: %{answer: :deny}}}
    },
    %{
      name: "editor",
      args: :none,
      description: "edit the draft in $EDITOR (Ctrl+E)",
      run: {:dispatch, %{type: :edit_draft}}
    },
    %{
      name: "help",
      args: :none,
      description: "list every command in the transcript",
      run: :help
    },
    %{
      name: "interrupt",
      args: :none,
      description: "stop the current turn (Esc)",
      run: {:dispatch, %{type: :interrupt}}
    },
    %{
      name: "memory",
      args: :none,
      description: "open the memory panel",
      run: {:dispatch, %{type: :open_panel, payload: %{panel: :memory}}}
    },
    %{
      name: "palette",
      args: :none,
      description: "open the command palette",
      run: {:dispatch, %{type: :open_palette}}
    },
    %{
      name: "quit",
      args: :none,
      description: "leave the harness (works with a non-empty draft)",
      run: :quit
    },
    %{
      name: "rules",
      args: :none,
      description: "open the rules panel",
      run: {:dispatch, %{type: :open_panel, payload: %{panel: :rules}}}
    },
    %{
      name: "session",
      args: :none,
      description: "seal a session summary into the transcript",
      run: :session
    },
    %{
      name: "steer",
      args: :text,
      description: "queue a steer for the next boundary (Tab)",
      run: :steer
    },
    %{
      name: "worktracks",
      args: :none,
      description: "open the worktracks panel",
      run: {:dispatch, %{type: :open_panel, payload: %{panel: :worktracks}}}
    }
  ]

  @doc "Every registered command, sorted by name."
  @spec all() :: [entry()]
  def all, do: @entries

  @doc """
  Prefix-matches `query` (no leading slash) against command names.
  An empty query matches everything — the bare `/` shows the full
  vocabulary.
  """
  @spec match(String.t()) :: [entry()]
  def match(query) when is_binary(query) do
    Enum.filter(@entries, &String.starts_with?(&1.name, query))
  end

  @doc "The exact-name entry, or nil."
  @spec find(String.t()) :: entry() | nil
  def find(name) when is_binary(name),
    do: Enum.find(@entries, &(&1.name == name))

  @doc """
  Splits a slash draft into `{query, args}` — `"/steer fix it"` →
  `{"steer", "fix it"}`, `"/"` → `{"", ""}`. Returns `:not_slash` for
  anything that does not START with `/` (a mid-text slash is text) and
  for multi-line drafts (a slash command is a one-line utterance).
  """
  @spec parse(String.t()) :: {String.t(), String.t()} | :not_slash
  def parse("/" <> rest) do
    if String.contains?(rest, "\n") do
      :not_slash
    else
      case String.split(rest, " ", parts: 2) do
        [name] -> {name, ""}
        [name, args] -> {name, String.trim(args)}
      end
    end
  end

  def parse(_other), do: :not_slash
end
