defmodule Raxol.UI.RegionPolicy do
  @moduledoc """
  Focus-driven region prominence — the pure policy function of
  `docs/proposals/in-flight/region-prominence-propagation.md` §3.2/§9 Phase 4:

      region_prominence(region_tree, focus, overlays) :: %{region_path => float}

  A region is identified by its `region_path` — a list of region ids,
  root-first (`[:app, :main, :diff_pane]`). `region_tree` here is the flat
  set of distinct paths actually present in a frame (SAL-POL-05 discipline —
  no processes, no clocks, no hidden state: same three arguments always
  produce the same map).

  ## Composition (design doc §3.2, §5)

  Each region's prominence is the product of two independent factors:

    * **focus weight** — `1.0` if `focus` is `nil`, or if the region is the
      focused path itself or one of its ancestors/descendants (the whole
      focused *lineage* lights up — "a focused input must not dim its own
      panel"); `@peer_level` (`#{0.8}`) otherwise. The opt-in `depth_falloff:
      true` variant replaces the flat peer level with a proportional
      falloff by tree distance from the focused path (siblings d=1,
      uncle-subtrees d=2, …): `max(1.0 - 0.2·d, 0.4)`. Default OFF — the
      two-level default is predictable and covers the sidebar/main case
      (§3.2 "Proportional variant").
    * **overlay weight** — the product, over every active dimming overlay
      (a mounted modal's own region), of `@overlay_keep` (`#{0.45}`) for
      every region that is NOT the overlay's own region or a *descendant*
      of it. Unlike the focus rule, this is one-directional: an overlay
      dims everything behind it, including its own ANCESTOR regions (a
      modal nested inside another modal's region still dims the outer
      modal once) — only the overlay's own subtree is exempt. This is what
      makes nested overlays compose correctly (§5 "Nested modals": the top
      modal is LIT, the mid modal is OVERLAID once, the base app twice).

  The two factors multiply (§4 C1's monoid — commutative, associative,
  `1.0` the identity, never raises prominence), then the **regional
  product** is floored at `@regional_floor` (`#{0.4}`, RP-P-10) — the same
  ladder floor `Raxol.Harness.RecencyPolicy` uses ("no new tiers" fence);
  below that reads as "broken terminal" per the design doc §5.

  ## Neutrality (RP-P-09)

  `focus: nil, overlays: []` ⇒ every region resolves to exactly `1.0` — an
  app that never focuses a region and never mounts an overlay renders
  byte-identically to pre-region code. This is the Phase 0-3 default,
  preserved: `Raxol.UI.Layout.Engine`'s modal-only Phase 1 mechanism is
  reproduced exactly as the `focus: nil` / single-overlay case of this
  general policy (see that module's `stamp_region_prominence/2`).

  ## Needs-input floor — NOT this module's job

  The per-content `needs_input` starvation guard (`Raxol.UI.Harness.
  Prominence.needs_input_floor/0`, `#{0.6}`) composes with this module's
  output *downstream*, at the `own_p * region_p` composition point — it is
  a property of content, not of a region (design doc §5: "the guard is
  per-CONTENT, not per-region"), so it does not belong in a pure
  region-only policy. Callers compose it themselves:
  `max(own_p * Map.fetch!(region_prominence(...), path), Prominence.needs_input_floor())`.
  """

  alias Raxol.UI.Harness.Prominence

  @typedoc "A region path — a list of region ids, root-first. `[]` is the implicit, unmarked root region."
  @type region_path :: [term()]

  # The ladder step a non-focused, non-overlay peer region drops to (design
  # doc §3.2 "Every other region: one ladder step down"). Matches the
  # shipped 1.0/0.8/0.6/0.4 recency ladder's second rung.
  @peer_level 0.8

  # The multiplier a mounted dimming overlay (a modal) applies to every
  # region not in its own subtree. MUST equal
  # `Raxol.UI.Layout.Engine.@overlay_keep` (== `Raxol.UI.CellDim.@contrast_keep`,
  # 0.45) so the Phase 1 modal look survives Phase 4's generalization
  # byte-for-byte (RP-N-02).
  @overlay_keep 0.45

  # §5 "Composition floor": the regional product (after both factors) never
  # drops below this — matches `Raxol.Harness.RecencyPolicy`'s floor, the
  # same 1.0/0.8/0.6/0.4 ladder's last rung. RP-P-10.
  @regional_floor 0.4

  # The `depth_falloff: true` opt-in's per-step decay and floor (§3.2
  # "Proportional variant") — same floor value as the composition floor
  # above, by design (the doc gives both as `0.4`).
  @depth_falloff_step 0.2
  @depth_falloff_floor 0.4

  @doc "The default peer-level prominence (one ladder step down from focus)."
  @spec peer_level() :: float()
  def peer_level, do: @peer_level

  @doc "The overlay dimming multiplier (matches the shipped modal look)."
  @spec overlay_keep() :: float()
  def overlay_keep, do: @overlay_keep

  @doc "The regional-product composition floor (§5, RP-P-10)."
  @spec regional_floor() :: float()
  def regional_floor, do: @regional_floor

  @doc """
  Computes the region-prominence map for every path in `region_paths`.

  Pure and deterministic (SAL-POL-05): the same three positional arguments
  always yield the same map — no clock, no process state, no I/O.

  ## Arguments

    * `region_paths` — the region paths actually present this frame (a
      flat list; duplicates are fine, the result is keyed by unique path).
    * `focus` — the focused region's path, or `nil` for no focus (every
      region's focus weight is then `1.0` — neutrality, §3.2).
    * `overlays` — the region paths of every currently-mounted dimming
      overlay (e.g. an open modal's own region). `[]` for none.

  ## Options

    * `:peer_level` — override `@peer_level` (default `#{@peer_level}`).
    * `:depth_falloff` — `true` engages the proportional peer-level variant
      (default `false`, the flat two-level default per §3.2).

  Returns `%{region_path => float() in 0.0..1.0}`, one entry per unique
  path in `region_paths` (a path missing from `region_paths` is not a key
  in the result — callers default missing lookups to `1.0`, the identity,
  exactly like `Raxol.UI.Layout.Engine`'s existing marker convention).
  """
  @spec region_prominence(
          [region_path()],
          region_path() | nil,
          [region_path()],
          keyword()
        ) ::
          %{region_path() => float()}
  def region_prominence(region_paths, focus \\ nil, overlays \\ [], opts \\ [])
      when is_list(region_paths) and is_list(overlays) and is_list(opts) do
    peer_level = Keyword.get(opts, :peer_level, @peer_level)
    depth_falloff? = Keyword.get(opts, :depth_falloff, false)
    unique_paths = Enum.uniq(region_paths)

    Map.new(unique_paths, fn path ->
      focus_p =
        focus_weight(path, focus, peer_level, depth_falloff?, unique_paths)

      overlay_p = overlay_weight(path, overlays)

      composed =
        (focus_p * overlay_p)
        |> clamp01()
        |> max(@regional_floor)

      {path, composed}
    end)
  end

  # --- focus weight (§3.2 "focused region ... ancestor/descendant: 1.0") ---

  # No focus at all: every region is `1.0` (neutrality, RP-P-09).
  defp focus_weight(_path, nil, _peer_level, _depth_falloff?, _all_paths),
    do: 1.0

  defp focus_weight(path, focus, peer_level, false, _all_paths) do
    if lineage_related?(path, focus), do: 1.0, else: peer_level
  end

  # Proportional variant (§3.2, opt-in): distance-based falloff instead of
  # the flat peer level. `peer_level` is not consulted here — the doc gives
  # this variant its own fixed formula (`max(1.0 - 0.2·d, 0.4)`), and at
  # `d = 1` (siblings) it evaluates to `0.8`, the same value as the default
  # `@peer_level`, so the two variants agree at the nearest ring by
  # construction.
  defp focus_weight(path, focus, _peer_level, true, _all_paths) do
    if lineage_related?(path, focus) do
      1.0
    else
      distance = tree_distance(path, focus)
      max(1.0 - @depth_falloff_step * distance, @depth_falloff_floor)
    end
  end

  # `a` and `b` are the same region, or one is a (non-root) prefix of the
  # other — ancestor/descendant in EITHER direction. `[]` (the implicit,
  # unmarked root region) is only related to itself: it is never treated as
  # an "ancestor" of every other path, or the whole tree would always be
  # exempt from de-prominence the moment `[]` were ever focused.
  defp lineage_related?(a, a), do: true

  defp lineage_related?(a, b) do
    (a != [] and list_prefix?(a, b)) or (b != [] and list_prefix?(b, a))
  end

  # --- overlay weight (§3.2 "each active dimming overlay ... every region
  # not on its own path", §5 "Nested modals" — one-directional: only the
  # overlay's own subtree (itself + descendants) is exempt, NOT its
  # ancestors, so a nested modal still dims the modal that hosts it) ---

  defp overlay_weight(path, overlays) do
    Enum.reduce(overlays, 1.0, fn overlay_path, acc ->
      if on_overlay_subtree?(path, overlay_path),
        do: acc,
        else: acc * @overlay_keep
    end)
  end

  defp on_overlay_subtree?(path, path), do: true

  defp on_overlay_subtree?(path, overlay_path) do
    overlay_path != [] and list_prefix?(overlay_path, path)
  end

  # --- depth_falloff tree distance (§3.2 "siblings d=1, uncle-subtrees d=2") ---

  # Distance via the lowest common ancestor: each path's own length minus
  # the shared-prefix length, summed — the number of edges on the tree path
  # between the two nodes. Siblings (same parent, different leaf id) are
  # distance 2 under this metric in general, but the doc's own example
  # ("siblings d=1") treats the shared parent as free — so distance is
  # halved and rounded up, which reproduces "siblings d=1, uncle-subtrees
  # d=2" for the doc's own examples while staying a well-defined metric for
  # arbitrary nesting.
  defp tree_distance(a, b) do
    shared = common_prefix_length(a, b)
    edges = length(a) - shared + (length(b) - shared)
    ceil(edges / 2)
  end

  defp common_prefix_length([h | ta], [h | tb]),
    do: 1 + common_prefix_length(ta, tb)

  defp common_prefix_length(_a, _b), do: 0

  defp list_prefix?(prefix, list), do: List.starts_with?(list, prefix)

  defp clamp01(p) when p < 0.0, do: 0.0
  defp clamp01(p) when p > 1.0, do: 1.0
  defp clamp01(p), do: p

  @doc """
  Composes a content's own prominence with the region prominence at its
  `region_path`, applying the needs-input starvation guard (§5) when
  requested — the downstream composition the module doc's "Needs-input
  floor" section names. `prominence_map` is `region_prominence/4`'s output;
  a `region_path` missing from it composes as `1.0` (the identity, matching
  `Raxol.UI.Layout.Engine`'s existing marker default).

  `needs_input: true` floors the RESULT at
  `Raxol.UI.Harness.Prominence.needs_input_floor/0` — after composition, so
  no combination of region dim + own fade can starve pending-input content
  below ordinary context (RP-P-08).
  """
  @spec compose(float(), %{region_path() => float()}, region_path(), keyword()) ::
          float()
  def compose(own_p, prominence_map, region_path, opts \\ []) do
    region_p = Map.get(prominence_map, region_path, 1.0)
    composed = clamp01(own_p) * clamp01(region_p)

    if Keyword.get(opts, :needs_input, false) do
      max(composed, Prominence.needs_input_floor())
    else
      composed
    end
  end
end
