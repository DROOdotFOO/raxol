defmodule Raxol.UI.Components.Harness.BodyProvider do
  @moduledoc """
  The T5 seam: an explicit per-kind content-map contract, plus the mapping
  from a `%Raxol.UI.Components.Harness.Block{}`'s `kind` to the merged
  component that renders its EXPANDED body.

  Per `docs/proposals/in-flight/harness-ui-STATE.md`'s binding advisory
  note, this contract is defined BEFORE mounting: `Block.content` (T4) is
  a plain, kind-shaped map (see `Block`'s moduledoc, "Rendering"), and
  every known kind's shape is documented here as the schema a body map
  must satisfy to mount safely. `Raxol.UI.Components.Harness.BlockBody`
  (T5's fold-aware entry point) is the only caller in production code;
  this module is also directly test-facing so the schema and the
  kind-to-component mapping are independently exercisable.

  ## Which kinds mount here (and which never did / no longer do)

  Only two kinds have a real mounted component: `:message`
  (`MessageBlock`) and `:diff` (`DiffViewer`). Every other kind is
  `Block.render/2`'s own in BOTH fold states — `BlockBody` short-circuits
  `:tool_call`, `:reasoning`, and `:error` to `Block.render/2` (the
  machinery register / alarm line is `Block`'s compact form, and that
  short-circuit IS the production path), and an `:approval` block renders
  its referent + proposed diff + answer affordances through
  `Block.render/2` as well. `component_for/1` and `mount/2` refuse those
  kinds; `BlockBody` converts the refusal into its usual safe fallback.

  ## Per-kind content-map schema

  Required keys (validated by `validate/2`; optional keys are read with a
  safe default and never fail validation):

    * `:message`   -- required `:text` (the Markdown/plain body); optional
      `:role` (`:user | :assistant`, defaults to `:assistant`).
      `Block.extract_content(:message, ...)` populates it from the source
      events' payload `role` field (normalized: only an explicit user
      marker resolves `:user`; absent/unknown stays `:assistant`, the
      unmarked voice), so the value threaded here is the real speaker,
      not a constant default. The default remains for hand-built bodies
      that never carried a role.
    * `:diff`      -- required `:path`, `:old`, `:new`; optional
      `:language`. Mirrors `Raxol.UI.Components.Harness.DiffViewer`'s own
      prop names -- see `Block`'s `extract_diff_content/1` (T5 extension:
      no prior producer resolved `:diff` kind, so there was no existing
      shape to preserve).

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
    Block,
    DiffViewer,
    MarkdownBody,
    MessageBlock
  }

  @type kind :: Block.kind()
  @type body :: map()

  @required_keys %{
    message: [:text],
    diff: [:path, :old, :new]
  }

  @components %{
    message: MessageBlock,
    diff: DiffViewer
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
  inspects a value's shape): a content map that has every required key
  always passes, regardless of what those keys hold. Missing keys are
  named explicitly, in schema order, never a bare "invalid".
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
  The canonical merged component for `kind`'s expanded body. Only
  `:message` and `:diff` have one; every other kind is `Block.render/2`'s
  own through `BlockBody`'s short-circuit/fallback (see the moduledoc).
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

    * `kind` has no known component (`:opaque`, the short-circuited
      machinery/approval kinds, or anything else outside
      `known_kinds/0`);
    * `opts[:component]` is given and disagrees with `component_for/1` --
      refuses rather than silently rendering `kind`'s content through the
      wrong component (the "wrong-kind mount" guard: a caller asking to
      render a `:diff` body through `MessageBlock` is a programming
      error, not a fallback case);
    * `body` fails `validate/2`.

  ## Options

    * `:context` -- render context passed to every mounted component's
      `render/2` (default `%{}`); `:width` inside it sizes `:message`
      and `:diff` bodies.
    * `:seal` -- `:live | :sealed` (default `:sealed`), the block's own
      seal state. Threaded only into the `:message` body, as
      `MessageBlock`'s render `:mode` (`:live` -> `:streaming`, `:sealed`
      -> `:sealed`) -- a live message renders with the provisional-close
      streaming treatment, a sealed one as a plain full parse. Defaulting
      to `:sealed` means existing direct callers of `mount/3` see zero
      behavior change; `BlockBody` is the one caller that passes the
      block's real `seal`. Every other kind accepts and ignores it.
    * `:component` -- override the component actually mounted (for
      testing the wrong-kind refusal above); defaults to
      `component_for(kind)`.

  ## What `{:ok, _} | {:error, _}` does NOT cover

  The two-tuple result above covers this seam's OWN guard failures
  (unknown kind, wrong-kind override, schema validation) -- it does not
  catch an exception raised inside the mounted component's own `init/1`
  or `render/2` (a schema-valid but wrong-SHAPED prop reaching a
  component's internal guard/pattern match). This module keeps no
  try/rescue of its own, by design -- see
  `Raxol.UI.Components.Harness.BlockBody`'s moduledoc ("the rescue lives
  HERE, not inside `BodyProvider.mount/3`"). Production code never calls
  `mount/3` directly for exactly that reason: only `BlockBody.render/2`
  does, and it wraps the call so a component raise recovers to the same
  `{:error, reason}` shape this function returns for its own failures. A
  caller that reaches `mount/3` directly (as this module's own tests do)
  gets an uncaught raise on that path, not an `{:error, _}` tuple.
  """
  @spec mount(kind() | term(), body(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def mount(kind, body, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    seal = Keyword.get(opts, :seal, :sealed)

    with {:ok, expected_component} <- component_for(kind),
         component = Keyword.get(opts, :component, expected_component),
         :ok <- ensure_component(kind, component, expected_component),
         :ok <- validate(kind, body) do
      {:ok, build_view(kind, component, body, context, seal)}
    end
  end

  defp ensure_component(_kind, component, component), do: :ok

  defp ensure_component(kind, component, expected) do
    {:error,
     "refusing to mount #{inspect(component)} for #{inspect(kind)} block body " <>
       "(expects #{inspect(expected)})"}
  end

  # -- per-kind view construction ---------------------------------------

  defp build_view(:message, component, body, context, seal) do
    mount_one(component, message_props(body, context, seal), context)
  end

  defp build_view(:diff, component, body, context, _seal) do
    mount_one(component, diff_props(body, context), context)
  end

  defp mount_one(component, props, context) do
    {:ok, state} = component.init(props)
    component.render(state, context)
  end

  defp message_props(body, context, seal) do
    [
      role: Map.get(body, :role, :assistant),
      content: Map.fetch!(body, :text),
      width: width_from(context),
      mode: MarkdownBody.mode_for_seal(seal)
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

  defp width_from(context),
    do: Map.get(context, :width, Raxol.Core.Defaults.terminal_width())
end
