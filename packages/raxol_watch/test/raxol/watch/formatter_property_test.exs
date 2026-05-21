defmodule Raxol.Watch.FormatterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Watch.Formatter

  @max Formatter.max_body_length()

  describe "format_announcement/2 length invariants" do
    property "body length never exceeds max_body_length for any input" do
      check all message <- string(:utf8) do
        notif = Formatter.format_announcement(message)
        assert String.length(notif.body) <= @max
      end
    end

    property "short messages are passed through verbatim" do
      # Filter to messages whose grapheme count fits, since the
      # implementation's cap is in graphemes (visual width).
      check all message <- string(:utf8),
                String.length(message) <= @max do
        notif = Formatter.format_announcement(message)
        assert notif.body == message
      end
    end

    property "long messages are truncated to exactly max_body_length with ellipsis" do
      # ASCII guarantees grapheme count == codepoint count == byte count,
      # so min_length here lines up with the implementation's grapheme cap.
      check all message <- string(:ascii, min_length: @max + 1, max_length: @max * 2) do
        notif = Formatter.format_announcement(message)
        assert String.ends_with?(notif.body, "...")
        assert String.length(notif.body) == @max
      end
    end
  end

  describe "format_announcement/2 priority" do
    property "any priority atom produces a notification with a known push priority" do
      check all priority <- one_of([
                  constant(:high),
                  constant(:medium),
                  constant(:low),
                  constant(:normal),
                  atom(:alphanumeric)
                ]) do
        notif = Formatter.format_announcement("msg", priority)
        assert notif.priority in [:high, :normal, :silent]
      end
    end

    property "high priority always emits the acknowledge action" do
      check all message <- string(:utf8, max_length: 50) do
        notif = Formatter.format_announcement(message, :high)
        action_ids = Enum.map(notif.actions, & &1.id)
        assert "acknowledge" in action_ids
      end
    end

    property "high priority sets badge to 1, others to 0" do
      check all priority <- one_of([
                  constant(:medium),
                  constant(:low),
                  constant(:normal),
                  atom(:alphanumeric)
                ]) do
        assert Formatter.format_announcement("m", priority).badge == 0
      end

      assert Formatter.format_announcement("m", :high).badge == 1
    end
  end

  describe "format_model_summary/2 length invariants" do
    property "body length never exceeds max_body_length for any projections list" do
      check all projections <- projections_gen() do
        notif = Formatter.format_model_summary("title", projections)
        assert String.length(notif.body) <= @max
      end
    end

    property "small summaries preserve every label and value verbatim" do
      check all projections <- list_of(short_projection(), max_length: 3) do
        notif = Formatter.format_model_summary("title", projections)

        # If the rendered body fits under the cap, every label and value
        # must appear in the body. The implementation joins with newlines.
        if String.length(notif.body) < @max do
          for {label, value} <- projections do
            assert notif.body =~ label
            assert notif.body =~ to_string(value)
          end
        end
      end
    end

    property "default title is Raxol when no title is given" do
      check all projections <- list_of(short_projection(), max_length: 3) do
        assert Formatter.format_model_summary(projections).title == "Raxol"
      end
    end
  end

  # -- Generators --

  defp short_projection do
    tuple({
      string(:alphanumeric, min_length: 1, max_length: 12),
      one_of([
        string(:alphanumeric, min_length: 1, max_length: 12),
        integer()
      ])
    })
  end

  defp projections_gen do
    list_of(
      tuple({
        string(:utf8, max_length: 30),
        one_of([string(:utf8, max_length: 30), integer()])
      }),
      max_length: 20
    )
  end
end
