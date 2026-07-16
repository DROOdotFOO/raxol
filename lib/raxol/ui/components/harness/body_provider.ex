defmodule Raxol.UI.Components.Harness.BodyProvider do
  @moduledoc """
  The T5 seam: an explicit per-kind content-map contract, plus the mapping
  from a `%Raxol.UI.Components.Harness.Block{}`'s `kind` to the merged
  component (or pair of components) that renders its EXPANDED body.

  Per `docs/proposals/in-flight/harness-ui-STATE.md`'s binding advisory
  note, this contract is defined BEFORE mounting: `Block.content` (T4) is
  a plain, kind-shaped map (see `Block`'s moduledoc, "Rendering"), and
  every known kind's shape is documented here as the schema a body map
  must satisfy to mount safely. `Raxol.UI.Components.Harness.BlockBody`
  (T5's fold-aware entry point) is the only caller in production code;
  this module is also directly test-facing so the schema and the
  kind-to-component mapping are independently exercisable.

  ## Per-kind content-map schema

  Required keys (validated by `validate/2`; optional keys are read with a
  safe default and never fail validation):

    * `:message`   -- required `:text` (the Markdown/plain body); optional
      `:role` (`:user | :assistant`, defaults to `:assistant` -- `Block`'s
      own extraction never populates `:role` today, a documented gap, not
      a bug: a future projection unit can add it, contract-only-grows).
    * `:reasoning` -- required `:text`.
    * `:tool_call` -- required `:name`, `:args`; optional `:result`
      (`nil` while the call has no paired result yet) and `:tainted`
      (boolean, defaults `false`). Mirrors exactly what
      `Block.extract_content(:tool_call, ...)` already produces.
    * `:diff`      -- required `:path`, `:old`, `:new`; optional
      `:language`. Mirrors `Raxol.UI.Components.Harness.DiffViewer`'s own
      prop names -- see `Block`'s `extract_diff_content/1` (T5 extension:
      no prior producer resolved `:diff` kind, so there was no existing
      shape to preserve).
    * `:approval`  -- required `:action`, `:blast_radius`, `:options`.
      `:blast_radius` must be shaped like
      `Raxol.UI.Components.Harness.BlastRadiusPreview.blast_radius()`, or
      `nil` when no producer ever supplied one -- `nil` is a real,
      distinct value here, not a validation failure: `BlastRadiusPreview`
      renders it as an explicit "not declared, treat as unsafe" warning,
      never as its `%{}` "No tracked effects." line (a producer-declared
      empty blast radius is a different, calmer claim than one nobody
      declared at all). `:options` must be shaped like
      `Raxol.UI.Components.Harness.ApprovalPrompt.option()` for the
      mounted render to be meaningful -- `validate/2` only checks key
      PRESENCE (a cheap, always-safe check), not the value's inner shape;
      a wrongly-shaped value is the producer's bug, not something this
      seam can catch without becoming a second type-checker for every
      component's props.

  `:opaque` (Block's forward-compat fallback for an unrecognised kind) has
  no schema and no mountable component -- `component_for/1` and `mount/2`
  both refuse it; callers fall back to `Block.render/2`'s own opaque
  render, same as `BlockBody` does for any other mount failure.

  ## Fold-aware sizing

  This module only knows how to render the EXPANDED body. Folded
  rendering (one-line summary + outcome row) is `Block.render/2`'s own
  proven code path -- `BlockBody` reuses it directly rather than
  reimplementing a second summary renderer here.
  """

  alias Raxol.UI.Components.Harness.{
    ApprovalPrompt,
    Block,
    DiffViewer,
    MessageBlock,
    ReasoningBlock,
    ToolCallBlock,
    ToolResultBlock
  }

  @type kind :: Block.kind()
  @type body :: map()

  @required_keys %{
    message: [:text],
    reasoning: [:text],
    tool_call: [:name, :args],
    diff: [:path, :old, :new],
    approval: [:action, :blast_radius, :options]
  }

  @components %{
    message: MessageBlock,
    reasoning: ReasoningBlock,
    tool_call: ToolCallBlock,
    diff: DiffViewer,
    approval: ApprovalPrompt
  }

  @doc "Every kind this seam has a schema + mountable component for (excludes `:opaque`)."
  @spec known_kinds() :: [kind()]
  def known_kinds, do: Map.keys(@required_keys)

  @doc """
  The content-map keys `kind` requires. An unknown/`:opaque` kind has no
  schema -- an empty list, since `component_for/1` refuses it separately
  and `validate/2` on it always returns `:ok` (nothing to check, nothing
  to mount).
  """
  @spec required_keys(kind() | term()) :: [atom()]
  def required_keys(kind), do: Map.get(@required_keys, kind, [])

  @doc """
  Validates `body`'s keys against `kind`'s schema. Presence-only (never
  inspects a value's shape -- see the moduledoc's `:approval` note): a
  content map that has every required key always passes, regardless of
  what those keys hold. Missing keys are named explicitly, in schema
  order, never a bare "invalid".
  """
  @spec validate(kind() | term(), body()) :: :ok | {:error, String.t()}
  def validate(kind, body) when is_map(body) do
    case required_keys(kind) -- Map.keys(body) do
      [] -> :ok
      missing -> {:error, missing_keys_message(kind, missing)}
    end
  end

  def validate(kind, other) do
    {:error,
     "#{inspect(kind)} block body must be a map, got: #{inspect(other)}"}
  end

  defp missing_keys_message(kind, missing) do
    names = Enum.map_join(missing, ", ", &inspect/1)
    "#{inspect(kind)} block body missing required key(s): #{names}"
  end

  @doc """
  The canonical merged component for `kind`'s expanded body. `:tool_call`
  composes a second component (`ToolResultBlock`, only when a result is
  present) internally in `mount/2` -- this always names the primary one.
  """
  @spec component_for(kind() | term()) :: {:ok, module()} | {:error, String.t()}
  def component_for(kind) do
    case Map.fetch(@components, kind) do
      {:ok, component} -> {:ok, component}
      :error -> {:error, "no body component for kind #{inspect(kind)}"}
    end
  end

  @doc """
  Mounts `body` (a `kind`-shaped content map) through its real component,
  returning the rendered view map (`{:ok, view}`), or `{:error, reason}`
  when:

    * `kind` has no known component (`:opaque`, or anything else outside
      `known_kinds/0`);
    * `opts[:component]` is given and disagrees with `component_for/1` --
      refuses rather than silently rendering `kind`'s content through the
      wrong component (the "wrong-kind mount" guard: a caller asking to
      render a `:diff` body through `ApprovalPrompt` is a programming
      error, not a fallback case);
    * `body` fails `validate/2`.

  ## Options

    * `:context` -- render context passed to every mounted component's
      `render/2` (default `%{}`); `:width` inside it sizes `:message`,
      `:reasoning`, and `:diff` bodies.
    * `:outcome` -- a `Block.outcome()` map (default `%{}`), consulted
      only for `:tool_call` to derive the mounted status glyph
      (`:pending` with no result yet, `:failed` on a non-zero
      `exit_code`, `:done` otherwise) -- `Block.content` itself carries
      no status field of its own.
    * `:component` -- override the component actually mounted (for
      testing the wrong-kind refusal above); defaults to
      `component_for(kind)`.

  ## What `{:ok, _} | {:error, _}` does NOT cover

  The two-tuple result above covers this seam's OWN guard failures
  (unknown kind, wrong-kind override, schema validation) -- it does not
  catch an exception raised inside the mounted component's own `init/1`
  or `render/2` (a schema-valid but wrong-SHAPED prop reaching a
  component's internal guard/pattern match, see the `:approval` schema
  note above). This module keeps no try/rescue of its own, by design --
  see `Raxol.UI.Components.Harness.BlockBody`'s moduledoc ("the rescue
  lives HERE, not inside `BodyProvider.mount/3`"). Production code never
  calls `mount/3` directly for exactly that reason: only
  `BlockBody.render/2` does, and it wraps the call so a component raise
  recovers to the same `{:error, reason}` shape this function returns for
  its own failures. A caller that reaches `mount/3` directly (as this
  module's own tests do) gets an uncaught raise on that path, not an
  `{:error, _}` tuple.
  """
  @spec mount(kind() | term(), body(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def mount(kind, body, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    outcome = Keyword.get(opts, :outcome, %{})

    with {:ok, expected_component} <- component_for(kind),
         component = Keyword.get(opts, :component, expected_component),
         :ok <- ensure_component(kind, component, expected_component),
         :ok <- validate(kind, body) do
      {:ok, build_view(kind, component, body, outcome, context)}
    end
  end

  defp ensure_component(_kind, component, component), do: :ok

  defp ensure_component(kind, component, expected) do
    {:error,
     "refusing to mount #{inspect(component)} for #{inspect(kind)} block body " <>
       "(expects #{inspect(expected)})"}
  end

  # -- per-kind view construction ---------------------------------------

  defp build_view(:message, component, body, _outcome, context) do
    mount_one(component, message_props(body, context), context)
  end

  defp build_view(:reasoning, component, body, _outcome, context) do
    mount_one(component, reasoning_props(body, context), context)
  end

  defp build_view(:diff, component, body, _outcome, context) do
    mount_one(component, diff_props(body, context), context)
  end

  defp build_view(:approval, component, body, _outcome, context) do
    mount_one(component, approval_props(body), context)
  end

  defp build_view(:tool_call, component, body, outcome, context) do
    call_view = mount_one(component, tool_call_props(body, outcome), context)

    case Map.get(body, :result) do
      nil ->
        call_view

      result ->
        result_view =
          mount_one(
            ToolResultBlock,
            tool_result_props(body, result, outcome),
            context
          )

        # gap: 0 is load-bearing (matches every other harness component's
        # convention in this package): the layout engine defaults an
        # unset gap to 1, which would insert a blank row between the call
        # and its result.
        %{type: :column, style: %{}, gap: 0, children: [call_view, result_view]}
    end
  end

  defp mount_one(component, props, context) do
    {:ok, state} = component.init(props)
    component.render(state, context)
  end

  defp message_props(body, context) do
    [
      role: Map.get(body, :role, :assistant),
      content: Map.fetch!(body, :text),
      width: width_from(context)
    ]
  end

  defp reasoning_props(body, context) do
    [
      content: Map.fetch!(body, :text),
      # BlockBody only reaches mount/2 for the expanded fold state --
      # folded rendering is Block.render/2's own summary line, never this.
      expanded: true,
      width: width_from(context)
    ]
  end

  defp diff_props(body, context) do
    [
      path: Map.fetch!(body, :path),
      old: Map.fetch!(body, :old),
      new: Map.fetch!(body, :new),
      language: Map.get(body, :language),
      width: width_from(context)
    ]
  end

  defp approval_props(body) do
    [
      action: Map.fetch!(body, :action),
      blast_radius: Map.fetch!(body, :blast_radius),
      options: Map.fetch!(body, :options)
    ]
  end

  defp tool_call_props(body, outcome) do
    [
      name: Map.fetch!(body, :name),
      args: Map.fetch!(body, :args),
      status: tool_status(body, outcome)
    ]
  end

  defp tool_result_props(body, result, outcome) do
    [
      output: result,
      status: tool_status(body, outcome),
      taint: Map.get(body, :tainted, false),
      collapsed: false
    ]
  end

  defp tool_status(body, outcome) do
    case {Map.get(body, :result), Map.get(outcome, :exit_code)} do
      {nil, _exit_code} ->
        :pending

      {_result, exit_code} when is_integer(exit_code) and exit_code != 0 ->
        :failed

      _result_present_not_failed ->
        :done
    end
  end

  defp width_from(context),
    do: Map.get(context, :width, Raxol.Core.Defaults.terminal_width())
end
