defmodule Raxol.Playground.Demos.HarnessMessageBlockDemoTest do
  @moduledoc """
  Headless pins for `HarnessMessageBlockDemo` -- the U1-a autotest contract
  for the re-hosted MESSAGE block (harness TEA migration §7: the demo IS
  the fixture; body rendering, chevron grammar, prominence, fold/expand
  keys, and blank-row rhythm are asserted against the real rendered
  frame + buffer, precedent `modal_demo_headless_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

  @user_sigil "❯"
  @reply_sigil "❮"

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  defp start_demo(id) do
    {:ok, session} =
      Headless.start(Raxol.Playground.Demos.HarnessMessageBlockDemo, id: id)

    Process.sleep(200)
    session
  end

  defp lines(session) do
    {:ok, text} = Headless.screenshot(session)
    String.split(text, "\n")
  end

  defp cell(session, x, y) do
    {:ok, buffer} = Headless.get_buffer(session)
    buffer.cells |> Enum.at(y) |> Enum.at(x)
  end

  defp press(session, key) do
    :ok = Headless.send_key(session, key)
    Process.sleep(120)
    session
  end

  defp transcript_rows(rows) do
    hint_idx = Enum.find_index(rows, &String.contains?(&1, "focused:"))
    divider_idx = Enum.find_index(rows, &String.starts_with?(&1, "─"))
    Enum.slice(rows, (divider_idx + 1)..(hint_idx - 1))
  end

  describe "chevron grammar (mirrored outer-contour sigils)" do
    test "user ❯ and assistant ❮ sit in column 0 with content at the 2-cell indent" do
      session = start_demo(:msg_grammar)
      rows = lines(session)

      user_row = Enum.find(rows, &String.contains?(&1, "Run the tests"))
      assert String.at(user_row, 0) == @user_sigil
      assert String.at(user_row, 1) == " "

      assert String.slice(user_row, 2..-1//1)
             |> String.starts_with?("Run the tests")

      asst_row = Enum.find(rows, &String.contains?(&1, "Two suites are red"))
      assert String.at(asst_row, 0) == @reply_sigil
      assert String.at(asst_row, 1) == " "

      Headless.stop(session)
    end

    test "wrapped continuation rows keep the uniform 2-cell indent, sigil-free" do
      session = start_demo(:msg_wrap)
      rows = lines(session)

      continuation =
        Enum.find(rows, &String.contains?(&1, "until the renderer is green"))

      assert String.starts_with?(continuation, "  "),
             "a wrapped row must start at the 2-cell content indent"

      refute String.contains?(continuation, @user_sigil)
      refute String.contains?(continuation, @reply_sigil)

      Headless.stop(session)
    end

    test "sigils are the only column-0 dwellers in the transcript" do
      session = start_demo(:msg_col0)
      rows = lines(session)

      for row <- transcript_rows(rows), row != "" do
        assert String.at(row, 0) in [@user_sigil, @reply_sigil, " "],
               "column 0 of #{inspect(row)} must be a sigil or blank"
      end

      Headless.stop(session)
    end

    test "sigil cells render bold (structure channel), buffer-verified" do
      session = start_demo(:msg_bold)
      rows = lines(session)

      user_y = Enum.find_index(rows, &String.contains?(&1, "Run the tests"))
      asst_y = Enum.find_index(rows, &String.contains?(&1, "Two suites"))

      user_sigil_cell = cell(session, 0, user_y)
      asst_sigil_cell = cell(session, 0, asst_y)

      assert user_sigil_cell.char == @user_sigil
      assert user_sigil_cell.style.bold == true
      assert asst_sigil_cell.char == @reply_sigil
      assert asst_sigil_cell.style.bold == true

      Headless.stop(session)
    end
  end

  describe "body rendering (markdown + recovered variants)" do
    test "markdown variant: list items render, code/bold markers are consumed" do
      session = start_demo(:msg_md)
      {:ok, text} = Headless.screenshot(session)

      assert text =~ "renderer_test.exs — the scroll anchor drops"
      # The bullet wraps under display-column width: assert wrap-stable
      # fragments, not a substring that spans the wrap point.
      assert text =~ "golden drift after the"
      assert text =~ "palette change"
      assert text =~ "Starting with the anchor;"

      refute text =~ "`", "code-span backticks must be consumed by the parse"
      refute text =~ "**", "bold markers must be consumed by the parse"

      Headless.stop(session)
    end

    test "recovered/damaged variant: content survives, raw ESC bytes never render" do
      session = start_demo(:msg_recovered)
      {:ok, text} = Headless.screenshot(session)

      assert text =~ "alarm text"
      assert text =~ "survived the reconnect"

      refute text =~ "\e",
             "a raw ESC byte reached the rendered frame -- sanitization broke"

      Headless.stop(session)
    end
  end

  describe "blank-row rhythm" do
    test "exactly one blank row between turns, none doubled in the transcript" do
      session = start_demo(:msg_rhythm)
      rows = lines(session)

      first_y = Enum.find_index(rows, &String.contains?(&1, "Run the tests"))
      assert Enum.at(rows, first_y + 1) == ""

      assert Enum.at(rows, first_y + 2) |> String.starts_with?(@reply_sigil),
             "exactly ONE blank row separates turn 1 from turn 2"

      transcript = transcript_rows(rows)

      transcript
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn pair ->
        refute pair == ["", ""],
               "doubled blank rows break the seal-time separator rhythm"
      end)

      Headless.stop(session)
    end
  end

  describe "fold/expand keys (send_key through the real app loop)" do
    test "z folds the focused turn to a dim ▸ summary and back" do
      session = start_demo(:msg_fold)

      press(session, "z")
      rows = lines(session)

      folded_row = Enum.find(rows, &String.contains?(&1, "▸ Run the tests"))
      assert folded_row, "z must fold the focused turn to a ▸ summary line"

      assert String.at(folded_row, 0) == @user_sigil,
             "a folded turn keeps its speaker sigil"

      folded_y = Enum.find_index(rows, &String.contains?(&1, "▸ Run the tests"))
      folded_cell = cell(session, 2, folded_y)
      assert folded_cell.char == "▸"

      assert folded_cell.style.faint == true,
             "the folded summary must render dim (faint) in the buffer"

      press(session, "z")
      rows_after = lines(session)

      assert Enum.any?(
               rows_after,
               &(&1 == "#{@user_sigil} Run the tests and summarize what broke.")
             ),
             "a second z must restore the expanded body"

      Headless.stop(session)
    end

    test "j moves focus; z then folds the newly focused turn" do
      session = start_demo(:msg_focus)

      press(session, "j")
      {:ok, text} = Headless.screenshot(session)
      assert text =~ "focused: msg-2"

      press(session, "z")
      {:ok, folded} = Headless.screenshot(session)

      assert folded =~ "▸ Two suites are red:"

      refute folded =~ "renderer_test.exs",
             "folding msg-2 must hide its markdown body"

      Headless.stop(session)
    end
  end
end
