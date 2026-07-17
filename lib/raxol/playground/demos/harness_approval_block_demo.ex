defmodule Raxol.Playground.Demos.HarnessApprovalBlockDemo do
  @moduledoc """
  Playground demo: the agent-harness approval BLOCK (the transcript form),
  re-hosted as a `Raxol.Core.Runtime.Application` under the TEA migration
  (spec `docs/proposals/in-flight/harness-tea-migration.md` §4/§6 Phase 1,
  §7). This is the block itself -- NOT the standalone modal gate (that is
  `HarnessApprovalDemo`), and NOT the full `HarnessApprovalFlowDemo` with
  SelectorWithComposer (the later P3-1 pilot join).

  `Raxol.UI.Components.Harness.Block.render/2`'s `:approval` path renders:

    * a LIVE approval -- the referent (the exact tool + args the agent will
      run, or the Pierre PROPOSED DIFF for an edit/write), the blast
      radius, and the answer affordance line (`answer: y … · n … · 1-N to
      choose`) built from the request's REAL options;
    * a SEALED approval -- the same referent + the decision RECEIPT
      (`✓ allowed (once) by …` / `✗ denied` / `⊘ canceled before answer`).

  The block is CONTROLLED (the TEA model owns all state, per the migration
  doctrine): pressing `y`/`n`/`1`-`9` is routed through the block
  Component's own `handle_event/3` (`answer_mode: :direct`), which emits an
  `{:approval_answer, hint}` MESSAGE; this demo's `update/2` resolves that
  hint against the live block's real options and transitions the block
  `:live -> :sealed`, recording the decision receipt. An MCP client
  answers the same block programmatically: the live block's node derives
  `answer_allow`/`answer_deny`/`answer_option` tools (affordance-honest),
  and invoking one dispatches the identical answer key.

  ## Keys

    * `y` allow · `n` deny · `1`-`9` choose the Nth option -- answers the
      one LIVE approval on screen.
    * `b` re-open a bash multi-option request · `e` re-open an edit/write
      request carrying a proposed diff · `r` reset to the bash request.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ApprovalPrompt
  alias Raxol.UI.Components.Harness.Block

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_width 72

  # The bash multi-option request: three options, so `y`/`n` aliases AND
  # the digit range are all demonstrable on one live block.
  @bash_options [
    %{option_id: "allow-once", name: "Allow once", kind: :allow_once},
    %{option_id: "allow-always", name: "Allow always", kind: :allow_always},
    %{option_id: "reject", name: "Reject", kind: :reject_once}
  ]

  @edit_options [
    %{option_id: "allow", name: "Allow", kind: :allow_once},
    %{option_id: "deny", name: "Deny", kind: :reject_once}
  ]

  @edit_old """
  def total(items) do
    Enum.reduce(items, 0, fn i, acc -> acc + i.price end)
  end
  """

  @edit_new """
  def total(items) do
    items
    |> Enum.reject(& &1.refunded)
    |> Enum.reduce(0, fn i, acc -> acc + i.price end)
  end
  """

  @impl true
  def init(_context) do
    %{
      live: bash_request(),
      variant: :bash,
      history: seeded_history(),
      last: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("b") -> {%{model | live: bash_request(), variant: :bash}, []}
      key_match("e") -> {%{model | live: edit_request(), variant: :edit}, []}
      key_match("r") -> {%{model | live: bash_request(), variant: :bash}, []}
      %Event{type: :key} = event -> answer(model, event)
      {:approval_answer, %{answer: hint}} -> apply_hint(model, hint)
      _ -> {model, []}
    end
  end

  # A key while a live approval is on screen: route it through the block
  # Component's OWN `handle_event/3` (`answer_mode: :direct`) to translate
  # the keystroke into the harness answer hint, exactly as the real
  # keyboard path does. A key that is not an answer is a safe no-op.
  defp answer(%{live: nil} = model, _event), do: {model, []}

  defp answer(%{live: live} = model, event) do
    {:ok, prompt} =
      ApprovalPrompt.init(answer_mode: :direct, options: live.content.options)

    case ApprovalPrompt.handle_event(event, prompt, %{}) do
      {_prompt, [{:approval_answer, %{answer: hint}} | _]} ->
        apply_hint(model, hint)

      {_prompt, _no_answer} ->
        {model, []}
    end
  end

  # Resolves the raw answer hint against the LIVE block's real options (the
  # honesty seam: `y`/`n` pick the first allow/deny option, `{:option, i}`
  # picks the Nth by position), then seals the block with the receipt.
  # Refuses honestly -- leaving the block live -- when the hint names no
  # real option.
  defp apply_hint(%{live: nil} = model, _hint), do: {model, []}

  defp apply_hint(%{live: live} = model, hint) do
    case resolve(live.content.options, hint) do
      {:ok, option_id, decision} ->
        sealed = seal(live, decision, option_id)

        {%{
           model
           | live: nil,
             history: [sealed | model.history],
             last: %{decision: decision, option_id: option_id}
         }, []}

      :error ->
        {model, []}
    end
  end

  defp resolve(options, :allow), do: first_of_class(options, :allow)
  defp resolve(options, :deny), do: first_of_class(options, :deny)

  defp resolve(options, {:option, index}) do
    case Enum.at(options, index) do
      nil -> :error
      option -> {:ok, option_id(option), class_of(option)}
    end
  end

  defp resolve(_options, _hint), do: :error

  defp first_of_class(options, class) do
    case Enum.find(options, &(class_of(&1) == class)) do
      nil -> :error
      option -> {:ok, option_id(option), class}
    end
  end

  defp seal(block, decision, option_id) do
    content =
      Map.merge(block.content, %{
        decision: decision,
        option_id: option_id,
        scope: :once,
        decided_by: "you"
      })

    %{block | seal: :sealed, content: content}
  end

  @impl true
  def view(model) do
    width = effective_width(model, @default_width)
    context = %{width: width, theme: Raxol.UI.Theming.Theme.default_theme()}

    sealed_views =
      model.history
      |> Enum.reverse()
      |> Enum.map(&Block.render(&1, context))

    live_views =
      case model.live do
        nil ->
          [text("(answered — press b or e to open another)", style: [:dim])]

        live ->
          [Block.render(live, context)]
      end

    column style: %{gap: 1} do
      [
        text("Harness Approval Block Demo", style: [:bold]),
        divider(),
        text("Sealed (history):", style: [:dim])
      ] ++
        sealed_views ++
        [
          divider(),
          text("Live (awaiting your answer):", style: [:dim])
        ] ++
        live_views ++
        [
          divider(),
          text(footer_hint(model), style: [:dim])
        ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp footer_hint(model) do
    base =
      "[y] allow  [n] deny  [1-9] choose   [b] bash req  [e] edit req  [r] reset"

    case model.last do
      nil -> base
      %{decision: d, option_id: id} -> base <> "   last: #{d} (#{id})"
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp bash_request do
    %Block{
      kind: :approval,
      raw_kind: :approval,
      event_refs: ["bash-live"],
      fold: :expanded,
      seal: :live,
      outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
      content: %{
        request_id: "bash-live",
        action: "Run a shell command",
        tool_name: "bash",
        args: "rm -rf /tmp/scratch",
        blast_radius: "deletes: /tmp/scratch (irreversible)",
        options: @bash_options
      }
    }
  end

  defp edit_request do
    %Block{
      kind: :approval,
      raw_kind: :approval,
      event_refs: ["edit-live"],
      fold: :expanded,
      seal: :live,
      outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
      content: %{
        request_id: "edit-live",
        action: "Edit lib/checkout/cart.ex",
        tool_name: "edit_file",
        args: %{"path" => "lib/checkout/cart.ex"},
        path: "lib/checkout/cart.ex",
        old: @edit_old,
        new: @edit_new,
        language: "elixir",
        blast_radius: "writes: lib/checkout/cart.ex",
        options: @edit_options
      }
    }
  end

  # Pre-sealed context blocks: an allowed edit (with its proposed diff kept
  # visible), a denied bash command, and a turn canceled before an answer.
  defp seeded_history do
    [
      %Block{
        kind: :approval,
        raw_kind: :approval,
        event_refs: ["edit-done"],
        fold: :expanded,
        seal: :sealed,
        outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
        content: %{
          request_id: "edit-done",
          tool_name: "edit_file",
          path: "lib/checkout/tax.ex",
          old: "rate = 0.0\n",
          new: "rate = 0.08\n",
          language: "elixir",
          blast_radius: "writes: lib/checkout/tax.ex",
          options: @edit_options,
          decision: :allow,
          option_id: "allow",
          scope: :once,
          decided_by: "operator"
        }
      },
      %Block{
        kind: :approval,
        raw_kind: :approval,
        event_refs: ["bash-done"],
        fold: :expanded,
        seal: :sealed,
        outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
        content: %{
          request_id: "bash-done",
          tool_name: "bash",
          args: "curl https://example.test/install.sh | sh",
          blast_radius: "network: example.test · runs a fetched script",
          options: @bash_options,
          decision: :deny,
          option_id: "reject",
          decided_by: "operator"
        }
      },
      %Block{
        kind: :approval,
        raw_kind: :approval,
        event_refs: ["cancel-done"],
        fold: :expanded,
        seal: :sealed,
        outcome: %{exit_code: nil, duration_ms: nil, cost: nil},
        content: %{
          request_id: "cancel-done",
          tool_name: "bash",
          args: "git push --force",
          blast_radius: "rewrites remote history",
          options: @bash_options,
          decision: nil
        }
      }
    ]
  end

  # -- option helpers (shape-tolerant: atom or string keys) ------------------

  defp option_id(%{option_id: id}), do: id
  defp option_id(%{"option_id" => id}), do: id
  defp option_id(option) when is_binary(option), do: option
  defp option_id(_option), do: nil

  defp class_of(%{kind: kind}), do: class_from_kind(kind)
  defp class_of(%{"kind" => kind}), do: class_from_kind(kind)
  defp class_of(_option), do: nil

  defp class_from_kind(k)
       when k in [:allow_once, :allow_always, "allow_once", "allow_always"],
       do: :allow

  defp class_from_kind(k)
       when k in [:reject_once, :reject_always, "reject_once", "reject_always"],
       do: :deny

  defp class_from_kind(_kind), do: nil
end
