defmodule Raxol.UI.Layout.FlexItem do
  @moduledoc """
  A flex child resolved into the inputs the flexible-length solver needs.

  This is the interface contract for the flex rework (proposal:
  `docs/proposals/in-flight/flex-spec-convergence.md`, Phase A). One
  `FlexItem` is resolved per child BEFORE distribution; the solver
  (`Distributor`) then works exclusively on these — it never reads raw
  elements or style maps.

  ## Semantics

    * `base_size` — the item's flex base size (resolved `flex-basis`).
      `:auto` basis resolves to the content main size via the measure
      function passed to `resolve/4`.
    * Terminal-pragmatic `flex: 1` (D2): the integer shorthand
      `style: %{flex: n}` expands to grow n / shrink 1 / basis 0 AND
      `min_main: 0`, so equal columns actually equalize. An explicit
      `min_width`/`min_height` in style still wins over the sugar.
    * Percentages: `{:pct, n}`. Resolved against the container's
      corresponding dimension when it is definite; against an indefinite
      dimension a percentage behaves as `:auto` (spec). Margin percentages
      resolve against the container's WIDTH regardless of side (spec).
    * Invalid values (negative sizes, negative flex factors, malformed
      percentages) are clamped to the nearest valid value and reported via
      the `[:raxol, :layout, :invalid_style]` telemetry event (D8) — layout
      never raises on style input.
    * `margin` sides may be `:auto`; sizing math treats `:auto` as 0
      (`outer_main/2`), positioning distributes free space into them (P3
      auto-margin step, solver-adjacent but not solver-owned).

  ## Solver fields

  `frozen`, `frozen_reason` (`:inflexible | :min_violation | :max_violation`)
  and `main_size` belong to the resolve-flexible-lengths loop (N6). They are
  defined here so the struct is the single currency between resolution,
  distribution, and positioning.
  """

  @type dimension :: non_neg_integer() | :infinity
  @type margin_side :: non_neg_integer() | :auto
  @type pct :: {:pct, number()}

  @type t :: %__MODULE__{
          element: map(),
          base_size: non_neg_integer(),
          min_main: non_neg_integer(),
          max_main: dimension(),
          grow: non_neg_integer(),
          shrink: non_neg_integer(),
          margin: {margin_side(), margin_side(), margin_side(), margin_side()},
          cross_size: non_neg_integer() | nil,
          min_cross: non_neg_integer(),
          max_cross: dimension(),
          align_self: atom() | nil,
          frozen: boolean(),
          frozen_reason: nil | :inflexible | :min_violation | :max_violation,
          main_size: non_neg_integer() | nil
        }

  defstruct element: nil,
            base_size: 0,
            min_main: 0,
            max_main: :infinity,
            grow: 0,
            shrink: 1,
            margin: {0, 0, 0, 0},
            cross_size: nil,
            min_cross: 0,
            max_cross: :infinity,
            align_self: nil,
            frozen: false,
            frozen_reason: nil,
            main_size: nil

  @doc """
  Resolves a raw child element into a `FlexItem`.

    * `child` — element map (style read from `:style`, flex attrs also
      honored from legacy `child.attrs.flex` for back-compat)
    * `main_axis` — `:horizontal | :vertical`
    * `container` — `%{width: definite | nil, height: definite | nil}`;
      nil marks an indefinite dimension (percentages resolve to `:auto`)
    * `content_size_fun` — zero-arg fun returning the content main size;
      called ONLY when basis resolves to `:auto`
  """
  def resolve(child, main_axis, container, content_size_fun) do
    style = get_style(child)
    flex = lift_flex(style, Map.get(child, :attrs, %{}))

    {main_dim, cross_dim} = axis_dims(main_axis)
    container_main = Map.get(container, main_dim)
    container_cross = Map.get(container, cross_dim)

    explicit_main =
      resolve_dimension(axis_style(style, child, main_dim), container_main)

    base_size =
      case resolve_basis(flex.basis, container_main) do
        :auto ->
          case explicit_main do
            :auto -> non_neg(content_size_fun.())
            n -> n
          end

        n ->
          n
      end

    explicit_min = resolve_dimension(min_style(style, main_dim), container_main)

    min_main =
      case {explicit_min, flex.min_main_override} do
        {:auto, nil} -> 0
        {:auto, override} -> override
        {n, _} -> n
      end

    max_main =
      case resolve_dimension(max_style(style, main_dim), container_main) do
        :auto -> :infinity
        n -> n
      end

    cross_size =
      case resolve_dimension(
             axis_style(style, child, cross_dim),
             container_cross
           ) do
        :auto -> nil
        n -> n
      end

    min_cross =
      case resolve_dimension(min_style(style, cross_dim), container_cross) do
        :auto -> 0
        n -> n
      end

    max_cross =
      case resolve_dimension(max_style(style, cross_dim), container_cross) do
        :auto -> :infinity
        n -> n
      end

    %__MODULE__{
      element: child,
      base_size: base_size,
      min_main: min_main,
      max_main: max_main,
      grow: flex.grow,
      shrink: flex.shrink,
      margin: resolve_margin(child, style, Map.get(container, :width)),
      cross_size: cross_size,
      min_cross: min_cross,
      max_cross: max_cross,
      align_self: Map.get(style, :align_self) || legacy_align_self(child)
    }
  end

  @doc """
  Expands the `flex` shorthand plus explicit grow/shrink/basis keys.

  Returns `%{grow, shrink, basis, min_main_override}`.

    * `flex: n` (int)      -> grow n, shrink 1, basis 0, min_main_override 0  (D2)
    * `flex: {g, s, b}`    -> as given, no min override
    * `flex: %{...}` map   -> grow/shrink/basis keys, no min override
    * legacy `attrs.flex`  -> same as map form (lowest precedence)
  """
  def lift_flex(style, attrs \\ %{}) do
    legacy = Map.get(attrs, :flex, %{})

    defaults = %{
      grow: Map.get(legacy, :grow, 0),
      shrink: Map.get(legacy, :shrink, 1),
      basis: Map.get(legacy, :basis, :auto),
      min_main_override: nil
    }

    case Map.get(style, :flex) do
      nil ->
        read_explicit_flex_keys(style, defaults)

      n when is_integer(n) ->
        n = clamp_factor(n, :flex)
        %{grow: n, shrink: 1, basis: 0, min_main_override: 0}

      {g, s, b} ->
        %{
          grow: clamp_factor(g, :grow),
          shrink: clamp_factor(s, :shrink),
          basis: b,
          min_main_override: nil
        }

      %{} = m ->
        %{
          grow: clamp_factor(Map.get(m, :grow, defaults.grow), :grow),
          shrink: clamp_factor(Map.get(m, :shrink, defaults.shrink), :shrink),
          basis: Map.get(m, :basis, defaults.basis),
          min_main_override: nil
        }

      other ->
        invalid(:flex, other)
        defaults
    end
  end

  @doc """
  Resolves a single dimension value against a containing dimension.

  int -> int (clamped non-negative); `{:pct, n}` -> rounded share of a
  definite container, `:auto` against an indefinite one; nil/:auto -> :auto.
  """
  def resolve_dimension(nil, _container), do: :auto
  def resolve_dimension(:auto, _container), do: :auto

  def resolve_dimension(n, _container) when is_integer(n) do
    if n < 0 do
      invalid(:dimension, n)
      0
    else
      n
    end
  end

  def resolve_dimension({:pct, n}, container)
      when is_number(n) and is_integer(container) do
    if n < 0 do
      invalid(:pct, n)
      0
    else
      round(n / 100 * container)
    end
  end

  def resolve_dimension({:pct, _n}, _indefinite), do: :auto

  def resolve_dimension(other, _container) do
    invalid(:dimension, other)
    :auto
  end

  @doc "Outer main size: margins + size; :auto margins count as 0 here."
  def outer_main(%__MODULE__{} = item, size, main_axis) do
    {ms, me} = main_margins(item, main_axis)
    margin_int(ms) + size + margin_int(me)
  end

  @doc "Clamp a candidate main size into the item's [min_main, max_main]."
  def clamp_main(%__MODULE__{min_main: min, max_main: max}, size) do
    size |> max(min) |> min_cap(max)
  end

  @doc "Hypothetical main size: base size clamped (spec 9.7 step 1 input)."
  def hypothetical_main(%__MODULE__{} = item),
    do: clamp_main(item, item.base_size)

  @doc "Main-axis {start, end} margins for the given axis."
  def main_margins(%__MODULE__{margin: {_t, r, _b, l}}, :horizontal), do: {l, r}
  def main_margins(%__MODULE__{margin: {t, _r, b, _l}}, :vertical), do: {t, b}

  @doc "Cross-axis {start, end} margins for the given MAIN axis."
  def cross_margins(%__MODULE__{margin: {t, _r, b, _l}}, :horizontal),
    do: {t, b}

  def cross_margins(%__MODULE__{margin: {_t, r, _b, l}}, :vertical), do: {l, r}

  def margin_int(:auto), do: 0
  def margin_int(n) when is_integer(n), do: n

  # -- private ----------------------------------------------------------------

  defp get_style(child) do
    case Map.get(child, :style) do
      s when is_map(s) -> s
      s when is_list(s) -> Map.new(s)
      _ -> %{}
    end
  end

  defp read_explicit_flex_keys(style, defaults) do
    %{
      defaults
      | grow: clamp_factor(Map.get(style, :flex_grow, defaults.grow), :grow),
        shrink:
          clamp_factor(Map.get(style, :flex_shrink, defaults.shrink), :shrink),
        basis: Map.get(style, :flex_basis, defaults.basis)
    }
  end

  defp resolve_basis(:auto, _), do: :auto
  defp resolve_basis(b, container), do: resolve_dimension(b, container)

  defp axis_dims(:horizontal), do: {:width, :height}
  defp axis_dims(:vertical), do: {:height, :width}

  defp axis_style(style, child, dim) do
    Map.get(style, dim) || Map.get(child, dim)
  end

  defp min_style(style, :width), do: Map.get(style, :min_width)
  defp min_style(style, :height), do: Map.get(style, :min_height)
  defp max_style(style, :width), do: Map.get(style, :max_width)
  defp max_style(style, :height), do: Map.get(style, :max_height)

  defp resolve_margin(child, style, container_width) do
    raw = Map.get(style, :margin) || Map.get(child, :margin) || 0

    normalized =
      case raw do
        n when is_integer(n) or n == :auto ->
          {n, n, n, n}

        {h, v} ->
          {h, v, h, v}

        {_t, _r, _b, _l} = m ->
          m

        other ->
          invalid(:margin, other)
          {0, 0, 0, 0}
      end

    normalized
    |> Tuple.to_list()
    |> Enum.map(&resolve_margin_side(&1, container_width))
    |> List.to_tuple()
  end

  # Spec: margin percentages resolve against the container WIDTH for all sides.
  defp resolve_margin_side(:auto, _), do: :auto

  defp resolve_margin_side(v, container_width) do
    case resolve_dimension(v, container_width) do
      :auto -> 0
      n -> n
    end
  end

  defp legacy_align_self(child) do
    child |> Map.get(:attrs, %{}) |> Map.get(:align_self)
  end

  defp clamp_factor(n, _key) when is_integer(n) and n >= 0, do: n

  defp clamp_factor(n, key) do
    invalid(key, n)
    0
  end

  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(_), do: 0

  defp min_cap(n, :infinity), do: n
  defp min_cap(n, max) when is_integer(max), do: min(n, max)

  defp invalid(key, value) do
    :telemetry.execute(
      [:raxol, :layout, :invalid_style],
      %{count: 1},
      %{key: key, value: inspect(value)}
    )
  end
end
