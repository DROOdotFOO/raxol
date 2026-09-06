defmodule Raxol.Core.Telemetry.Invariants do
  @moduledoc """
  Declares the `:telemetry` events a package emits, each classified as exactly
  one of `:invariant`, `:peer` or `:operational`, and provides the source
  scanner that keeps such a declaration honest.

  ## Why this exists

  A telemetry event is only a guard if something fails when it fires.
  `Raxol.AgentClientProtocol.Session` detected a turn that produced zero
  `session/update` frames for a non-empty prompt, logged a warning AND emitted
  an event -- and the bug shipped anyway, because no test asserted on the
  event and the package did not even depend on `:telemetry`, so the emit site's
  `Code.ensure_loaded?/1` guard was permanently false. Classification turns
  "the system noticed and told nobody" into "the suite fails":

    * `:invariant` -- can only fire if Raxol itself is wrong. Enforced:
      `Raxol.Core.Telemetry.InvariantSentinel` fails any test in which one
      fires unless the test declares it with `@tag expect_invariant:`.
    * `:peer` -- caused by a remote party misbehaving (a chain RPC, a chat
      API, a peer agent, a malformed inbound frame). Not enforced.
    * `:operational` -- normal life: cache hits, policy decisions, lifecycle,
      retries, user API misuse, filesystem and clock reality. Not enforced.

  The criterion, applied literally: **if a peer, the network, the chain, the
  filesystem, the clock, or a user can cause it, it is NOT an invariant.** Err
  toward `:peer`/`:operational`. A false invariant makes the suite flaky, and a
  flaky guard gets deleted, which is strictly worse than a missed one.

  ## Why this module lives in `lib/` and not `test/support/`

  Dependent packages `use` this from THEIR test files, and a dependency's
  `test/support` tree is not on a consumer's load path -- only its `lib/` is
  compiled into the delivered application. Nothing here requires ExUnit at
  runtime: this module never touches it, and
  `Raxol.Core.Telemetry.InvariantSentinel` touches it only inside functions it
  injects into (or is called from) a test module.

  ## Usage

      defmodule Raxol.Payments.Telemetry do
        use Raxol.Core.Telemetry.Invariants,
          events: %{
            [:raxol, :payments, :xochi, :unchecked_settlement] => :invariant,
            [:raxol, :payments, :spend] => :operational
          },
          dynamic: [[:raxol, :earn, :buyer, :queue]]
      end

  That injects `events/0`, `invariant_events/0`, `dynamic_families/0` and
  `classification/1`.

  `events:` must be written as a literal map of literal event names, because
  the registry's whole value is being readable from source: a computed map
  could not be checked at compile time, and a duplicate key in a computed map
  would silently collapse rather than raise.

  ## Dynamic families

  Some events build their final segment at runtime
  (`[:raxol, :earn, :buyer, :queue, suffix]`). A source scan cannot enumerate
  those names, so the family prefix is declared in `dynamic:` instead. An entry
  is either a bare family (classified `:operational`) or a
  `{family, classification}` pair. A dynamic family may NOT be `:invariant`:
  the sentinel cannot subscribe to a name it cannot spell.

  ## Completeness is asserted, not trusted

  `scan_lib!/1` parses a package's `lib/` for the event literals actually
  passed to an emit call, so a per-package registry test can fail when a new
  event is added without anyone classifying it. That test is the load-bearing
  half of the mechanism.
  """

  @classifications [:invariant, :peer, :operational]

  # Function names whose first argument is a telemetry event name, matched
  # regardless of the module qualifying them: emission happens through
  # `:telemetry.execute/3` directly, through trace wrappers
  # (`TraceContext.execute/3`, a package's own `Telemetry.span/3`), and through
  # local `emit_telemetry`/`emit_event` helpers. `:telemetry.attach*` is
  # deliberately absent: subscribing to an event is not emitting it, and a
  # registry that demanded classification of events nobody emits is noise that
  # gets the completeness test disabled.
  @emit_functions [:execute, :span, :emit_telemetry, :emit_event]

  @typedoc "How a fired event should be read."
  @type classification :: :invariant | :peer | :operational

  @typedoc "A telemetry event name, or (for a dynamic family) its prefix."
  @type event :: [atom()]

  defmacro __using__(opts) do
    module = __CALLER__.module
    {events, dynamic} = parse_opts!(opts, module)

    invariants =
      events
      |> Enum.filter(fn {_event, class} -> class == :invariant end)
      |> Enum.map(fn {event, _class} -> event end)
      |> Enum.sort()

    families = dynamic |> Enum.map(fn {family, _class} -> family end) |> Enum.sort()

    quote do
      @raxol_telemetry_events unquote(Macro.escape(events))
      @raxol_telemetry_invariants unquote(Macro.escape(invariants))
      @raxol_telemetry_dynamic unquote(Macro.escape(dynamic))
      @raxol_telemetry_families unquote(Macro.escape(families))

      @doc """
      Every static telemetry event this package emits, mapped to its
      classification.
      """
      @spec events() :: %{
              Raxol.Core.Telemetry.Invariants.event() =>
                Raxol.Core.Telemetry.Invariants.classification()
            }
      def events, do: @raxol_telemetry_events

      @doc """
      The `:invariant` subset of `events/0`, sorted. These are the events
      `Raxol.Core.Telemetry.InvariantSentinel` arms.
      """
      @spec invariant_events() :: [Raxol.Core.Telemetry.Invariants.event()]
      def invariant_events, do: @raxol_telemetry_invariants

      @doc """
      Event families whose final segment is computed at runtime, sorted. A
      source scan cannot enumerate their full names, so a completeness test
      must not demand them as static keys.
      """
      @spec dynamic_families() :: [Raxol.Core.Telemetry.Invariants.event()]
      def dynamic_families, do: @raxol_telemetry_families

      @doc """
      The classification of `event`: an exact registry hit, else the longest
      matching dynamic family, else `nil` for an event this package does not
      declare.
      """
      @spec classification(Raxol.Core.Telemetry.Invariants.event()) ::
              Raxol.Core.Telemetry.Invariants.classification() | nil
      def classification(event) when is_list(event) do
        Raxol.Core.Telemetry.Invariants.classify(
          event,
          @raxol_telemetry_events,
          @raxol_telemetry_dynamic
        )
      end
    end
  end

  @doc """
  Resolve `event` against a static registry map and a list of
  `{family, classification}` dynamic entries.

  Exact matches win; otherwise the longest matching family prefix does, so a
  narrower family can refine a broader one.
  """
  @spec classify(event(), %{event() => classification()}, [{event(), classification()}]) ::
          classification() | nil
  def classify(event, events, dynamic) when is_list(event) do
    case Map.fetch(events, event) do
      {:ok, class} -> class
      :error -> dynamic_classification(event, dynamic)
    end
  end

  defp dynamic_classification(event, dynamic) do
    Enum.reduce(dynamic, nil, fn {family, class}, best ->
      cond do
        not List.starts_with?(event, family) -> best
        best == nil -> {length(family), class}
        elem(best, 0) < length(family) -> {length(family), class}
        true -> best
      end
    end)
    |> case do
      nil -> nil
      {_len, class} -> class
    end
  end

  # -- option parsing ---------------------------------------------------------

  defp parse_opts!(opts, module) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      bad_opts!(module, inspect(opts))
    end

    events = opts |> Keyword.fetch!(:events) |> parse_events!(module)
    dynamic = opts |> Keyword.get(:dynamic, []) |> parse_dynamic!(module, events)

    {events, dynamic}
  end

  defp parse_opts!(opts, module), do: bad_opts!(module, Macro.to_string(opts))

  defp bad_opts!(module, shown) do
    raise ArgumentError, """
    #{inspect(module)}: `use Raxol.Core.Telemetry.Invariants` takes a keyword
    list with a required `:events` map and an optional `:dynamic` list; got:

        #{shown}
    """
  end

  # The map is taken apart as AST rather than evaluated, for two reasons: a
  # duplicate key in an evaluated map would already have collapsed and could
  # not be reported, and a registry whose keys are not literals could not be
  # read out of source by a human or by scan_lib!/1.
  defp parse_events!({:%{}, _meta, pairs}, module) when is_list(pairs) do
    Enum.each(pairs, fn pair -> validate_pair!(pair, module) end)

    keys = Enum.map(pairs, fn {key, _class} -> key end)

    case duplicates(keys) do
      [] ->
        Map.new(pairs)

      dups ->
        raise ArgumentError, """
        #{inspect(module)}: duplicate event key(s) in `events:`:

            #{Enum.map_join(dups, "\n    ", &inspect/1)}

        Each event is classified exactly once. A duplicate means two authors
        disagreed about the same event, and the later row would silently win.
        """
    end
  end

  defp parse_events!(other, module) do
    raise ArgumentError, """
    #{inspect(module)}: `events:` must be a literal map of
    `[:raxol, ...] => :invariant | :peer | :operational`; got:

        #{Macro.to_string(other)}

    A computed map cannot be validated at compile time, and a duplicate key in
    one collapses silently instead of raising.
    """
  end

  defp validate_pair!({key, class}, module) do
    unless event_name?(key) do
      raise ArgumentError, """
      #{inspect(module)}: event key #{Macro.to_string(key)} is not a telemetry
      event name. Write it as a literal non-empty list of atoms, e.g.
      `[:raxol, :payments, :spend]`.
      """
    end

    unless class in @classifications do
      raise ArgumentError, """
      #{inspect(module)}: #{inspect(key)} is classified
      #{Macro.to_string(class)}, which is not one of
      #{inspect(@classifications)}.

      :invariant  -- can only fire if Raxol itself is wrong (enforced)
      :peer       -- a remote party misbehaved (not enforced)
      :operational-- normal life: cache, policy, lifecycle, retries, IO
      """
    end
  end

  defp validate_pair!(other, module) do
    raise ArgumentError,
          "#{inspect(module)}: `events:` entry #{Macro.to_string(other)} is not " <>
            "an `event => classification` pair"
  end

  defp parse_dynamic!(entries, module, events) when is_list(entries) do
    parsed = Enum.map(entries, fn entry -> parse_dynamic_entry!(entry, module) end)
    families = Enum.map(parsed, fn {family, _class} -> family end)

    case duplicates(families) do
      [] -> :ok
      dups -> raise ArgumentError, "#{inspect(module)}: duplicate dynamic family #{inspect(dups)}"
    end

    # A family that is also a static key means one name is being described two
    # ways: the completeness test would then both demand and excuse it.
    case Enum.filter(families, &Map.has_key?(events, &1)) do
      [] ->
        parsed

      both ->
        raise ArgumentError, """
        #{inspect(module)}: #{inspect(both)} appears in both `events:` and
        `dynamic:`. A name is either emitted as written (static) or extended
        with a runtime segment (dynamic), never both.
        """
    end
  end

  defp parse_dynamic!(other, module, _events) do
    raise ArgumentError,
          "#{inspect(module)}: `dynamic:` must be a literal list of event " <>
            "families; got #{Macro.to_string(other)}"
  end

  defp parse_dynamic_entry!({family, :invariant}, module) when is_list(family) do
    raise ArgumentError, """
    #{inspect(module)}: dynamic family #{inspect(family)} cannot be
    :invariant. The sentinel subscribes to exact event names, and this family's
    final segment is only known at runtime -- it cannot spell the name, so the
    guard would never arm. Classify the family :peer or :operational and, if a
    specific member of it really is an invariant, give that full name a static
    `events:` row.
    """
  end

  defp parse_dynamic_entry!({family, class}, module) do
    cond do
      not event_name?(family) ->
        raise ArgumentError, """
        #{inspect(module)}: dynamic family #{Macro.to_string(family)} is not a
        literal non-empty list of atoms.
        """

      class not in @classifications ->
        raise ArgumentError, """
        #{inspect(module)}: dynamic family #{inspect(family)} is classified
        #{Macro.to_string(class)}, which is not one of #{inspect(@classifications)}.
        """

      true ->
        {family, class}
    end
  end

  # A bare family is :operational: the enforced class is unavailable to it by
  # construction, and :operational is the safe reading of an unremarkable event.
  defp parse_dynamic_entry!(family, module) do
    if event_name?(family) do
      {family, :operational}
    else
      raise ArgumentError, """
      #{inspect(module)}: `dynamic:` entry #{Macro.to_string(family)} must be a
      literal non-empty list of atoms, optionally paired with a classification
      as `{family, :peer}`.
      """
    end
  end

  defp event_name?(name) when is_list(name) and name != [], do: Enum.all?(name, &is_atom/1)
  defp event_name?(_name), do: false

  defp duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_item, count} -> count > 1 end)
    |> Enum.map(fn {item, _count} -> item end)
  end

  # -- source scanner ---------------------------------------------------------

  @doc """
  Parse every `.ex` file under `lib_path` and return the sorted unique
  `[:raxol, ...]` event literals that appear as the FIRST ARGUMENT of an emit
  call.

  An emit call is any call -- local, or qualified by any module -- named
  `execute`, `span`, `emit_telemetry` or `emit_event` whose first argument is a
  literal `[:raxol, ...]` list of atoms. The rule is deliberately
  module-agnostic: this repo emits through `:telemetry.execute/3` directly, and
  also through wrappers (`Raxol.Core.Telemetry.TraceContext.execute/3`, a
  package's own `Telemetry.span/3`) that a `:telemetry`-only rule would miss,
  leaving a correctly classified event looking like a phantom registry row.
  In the other direction, `:telemetry.attach_many/4` takes event names too, but
  subscribing is not emitting, and a registry that demanded classification of
  events nobody emits would be noise that gets the completeness test disabled.

  A first argument given as a module attribute (`@telemetry_event
  [:raxol, ...]` then `:telemetry.execute(@telemetry_event, ...)`) is resolved
  against the literal attribute definitions in the same file.

  The scan is AST-based on purpose: an event named in a moduledoc or a comment
  is prose, not an emit site. Event names assembled at runtime
  (`[:raxol, :earn, :buyer, :queue, suffix]`) are not literals, so they never
  appear here -- declare them as `dynamic:` families instead.

  Raises when `lib_path` is not a directory or holds no `.ex` files, so a moved
  source tree fails loudly instead of letting a completeness test pass on an
  empty scan.
  """
  @spec scan_lib!(Path.t()) :: [event()]
  def scan_lib!(lib_path) do
    unless File.dir?(lib_path) do
      raise ArgumentError,
            "Raxol.Core.Telemetry.Invariants.scan_lib!/1: #{inspect(lib_path)} is not a " <>
              "directory. The source tree moved; a completeness test must not pass on an " <>
              "empty scan."
    end

    case lib_path |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort() do
      [] ->
        raise ArgumentError,
              "Raxol.Core.Telemetry.Invariants.scan_lib!/1: no .ex files under " <>
                "#{inspect(lib_path)}"

      files ->
        files |> Enum.flat_map(&scan_file!/1) |> Enum.uniq() |> Enum.sort()
    end
  end

  defp scan_file!(path) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path, columns: false)

    collect_events(ast, attribute_events(ast))
  end

  # Attributes are gathered file-wide first, because an attribute may be
  # defined after the function that emits with it.
  defp attribute_events(ast) do
    {_ast, table} =
      Macro.prewalk(ast, %{}, fn
        {:@, _meta, [{name, _nmeta, [value]}]} = node, acc when is_atom(name) ->
          if event_literal?(value),
            do: {node, Map.update(acc, name, [value], &[value | &1])},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    table
  end

  defp collect_events(ast, attributes) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn node, acc -> collect_node(node, acc, attributes) end)

    Enum.reverse(found)
  end

  defp collect_node({{:., _, [_target, fun]}, _meta, [first | _]} = node, acc, attributes)
       when fun in @emit_functions do
    {node, take_events(first, acc, attributes)}
  end

  defp collect_node({fun, _meta, [first | _]} = node, acc, attributes)
       when fun in @emit_functions do
    {node, take_events(first, acc, attributes)}
  end

  defp collect_node(node, acc, _attributes), do: {node, acc}

  defp take_events({:@, _meta, [{name, _nmeta, nil}]}, acc, attributes) do
    Enum.reduce(Map.get(attributes, name, []), acc, &[&1 | &2])
  end

  defp take_events(candidate, acc, _attributes) do
    if event_literal?(candidate), do: [candidate | acc], else: acc
  end

  defp event_literal?(candidate),
    do: event_name?(candidate) and hd(candidate) == :raxol
end
