defmodule Raxol.Property.PromoteDoToChildrenTest do
  @moduledoc """
  Property tests for `Raxol.Core.Renderer.View.promote_do_to_children/1`.

  This helper exists to fix a single, sharply-defined bug: when a demo
  writes `column(style: ..., do: var)` Elixir parses it as a one-arg
  keyword-list call, which matches `def column/1` instead of
  `defmacro column/2`. Without `promote_do_to_children`, the `:do` key
  rides along into the layout function and is silently ignored, leaving
  the column with empty children.

  The helper:

      def promote_do_to_children(opts) when is_list(opts) do
        case Keyword.pop(opts, :do) do
          {nil, opts} -> opts
          {block, opts} -> Keyword.put_new(opts, :children, List.wrap(block))
        end
      end

      def promote_do_to_children(opts), do: opts

  These properties pin its behavior down so a future refactor cannot
  re-open the original bug without lighting up at least one test.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Raxol.Core.Renderer.View

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "promote_do_to_children/1 invariants" do
    property ":do never appears in the result" do
      check all(opts <- kwlist_with_maybe_do(), max_runs: 200) do
        result = View.promote_do_to_children(opts)
        refute Keyword.has_key?(result, :do)
      end
    end

    property "no-op when :do is absent" do
      check all(opts <- kwlist_without_do(), max_runs: 200) do
        assert View.promote_do_to_children(opts) == opts
      end
    end

    property ":do value becomes :children (when no :children already)" do
      # Nil is excluded here because `Keyword.pop/2` cannot distinguish
      # `[do: nil]` from `[]` — both return `{nil, [...]}`. The helper's
      # contract for `do: nil` is documented by its own property below.
      check all(
              opts <- kwlist_without_children_or_do(),
              do_value <- non_nil_do_value_gen(),
              max_runs: 200
            ) do
        with_do = Keyword.put(opts, :do, do_value)
        result = View.promote_do_to_children(with_do)

        assert Keyword.get(result, :children) == List.wrap(do_value),
               """
               Expected :children to be List.wrap(do_value).

               Input:  #{inspect(with_do)}
               Result: #{inspect(result)}
               """
      end
    end

    property "do: nil is indistinguishable from no :do key" do
      # Real-world callers don't typically write `column(do: nil)`, but
      # `column(do: maybe_nil_helper(model))` can produce that shape if
      # `maybe_nil_helper` returns nil under some state. The helper
      # currently treats `[do: nil]` as a no-op (no `:children` is set).
      # This property documents that behavior so any future change is
      # deliberate, not accidental.
      check all(opts <- kwlist_without_children_or_do(), max_runs: 100) do
        result_without_do = View.promote_do_to_children(opts)
        result_with_nil_do = View.promote_do_to_children(Keyword.put(opts, :do, nil))

        assert result_without_do == result_with_nil_do,
               """
               do: nil produced a different result than no :do.

               Without :do:    #{inspect(result_without_do)}
               With :do=nil:   #{inspect(result_with_nil_do)}
               """
      end
    end

    property "existing :children is NOT overwritten by :do" do
      # When both keys are present, put_new should preserve the original
      # :children. If we ever switched to Keyword.put it would silently
      # clobber state the caller intentionally set.
      check all(
              opts <- kwlist_without_children_or_do(),
              children <- list_of(printable_text(), max_length: 3),
              do_value <- do_value_gen(),
              max_runs: 200
            ) do
        with_both =
          opts
          |> Keyword.put(:children, children)
          |> Keyword.put(:do, do_value)

        result = View.promote_do_to_children(with_both)

        assert Keyword.get(result, :children) == children,
               """
               :children was overwritten when :do was also present.

               Input :children:  #{inspect(children)}
               Input :do:        #{inspect(do_value)}
               Result :children: #{inspect(Keyword.get(result, :children))}
               """
      end
    end

    property "all non-:do keys are preserved with original values" do
      # The helper only ever touches :do and :children. Everything else
      # must round-trip unchanged.
      check all(opts <- kwlist_with_maybe_do(), max_runs: 200) do
        result = View.promote_do_to_children(opts)
        other_keys = Keyword.keys(opts) -- [:do]

        for key <- other_keys, uniq_key?(opts, key) do
          assert Keyword.get(result, key) == Keyword.get(opts, key),
                 """
                 Key #{inspect(key)} mutated.

                 Input:  #{inspect(opts)}
                 Result: #{inspect(result)}
                 """
        end
      end
    end

    property "non-list inputs pass through unchanged" do
      check all(non_list <- non_list_input(), max_runs: 200) do
        assert View.promote_do_to_children(non_list) == non_list
      end
    end

    property "idempotent — applying twice equals applying once" do
      # Once :do is gone, a second pass is a no-op. Locks in the
      # second-clause behavior.
      check all(opts <- kwlist_with_maybe_do(), max_runs: 200) do
        once = View.promote_do_to_children(opts)
        twice = View.promote_do_to_children(once)
        assert once == twice
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp kwlist_with_maybe_do do
    gen all(
          base <- kwlist_without_do(),
          include_do? <- boolean(),
          do_value <- do_value_gen()
        ) do
      if include_do?, do: Keyword.put(base, :do, do_value), else: base
    end
  end

  defp kwlist_without_do do
    list_of(
      gen all(
            key <- safe_key_gen(),
            value <- arbitrary_value_gen()
          ) do
        {key, value}
      end,
      min_length: 0,
      max_length: 5
    )
    |> map(&dedupe_keys/1)
    |> filter(fn kwlist -> not Keyword.has_key?(kwlist, :do) end)
  end

  defp kwlist_without_children_or_do do
    kwlist_without_do()
    |> filter(fn kwlist -> not Keyword.has_key?(kwlist, :children) end)
  end

  defp safe_key_gen do
    # Pick from a small fixed set of atoms so kwlists are likely to have
    # collisions to dedupe (matching the real demo call sites).
    member_of([:style, :padding, :border, :width, :height, :align, :justify, :gap, :children])
  end

  defp arbitrary_value_gen do
    one_of([
      integer(0..10),
      string(:printable, max_length: 8),
      member_of([:single, :double, :rounded, :none, :stretch, :start, :center]),
      constant(%{}),
      constant([])
    ])
  end

  defp do_value_gen do
    # The block of a `do:` is typically a list of children, a single child
    # element, or — pathologically — nil. List.wrap handles all three.
    one_of([
      list_of(child_node(), min_length: 0, max_length: 4),
      child_node(),
      constant(nil)
    ])
  end

  defp non_nil_do_value_gen do
    one_of([
      list_of(child_node(), min_length: 0, max_length: 4),
      child_node()
    ])
  end

  defp child_node do
    gen all(content <- printable_text()) do
      %{type: :text, content: content}
    end
  end

  defp printable_text do
    gen all(
          s <- string([?a..?z, ?A..?Z, ?0..?9], min_length: 1, max_length: 6),
          String.trim(s) != ""
        ) do
      s
    end
  end

  defp non_list_input do
    one_of([
      integer(0..100),
      string(:printable, max_length: 6),
      constant(nil),
      constant(:atom_input),
      constant(%{some: :map}),
      constant({:tuple, :input})
    ])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # StreamData can emit kwlists with duplicate keys; Keyword.put_new and
  # Keyword.pop only see the first occurrence, so the comparison would be
  # spurious. Dedupe by keeping the first value per key.
  defp dedupe_keys(kwlist) do
    Enum.reduce(kwlist, [], fn {k, v}, acc ->
      if Keyword.has_key?(acc, k), do: acc, else: Keyword.put(acc, k, v)
    end)
  end

  defp uniq_key?(kwlist, key) do
    Enum.count(kwlist, fn {k, _} -> k == key end) == 1
  end
end
