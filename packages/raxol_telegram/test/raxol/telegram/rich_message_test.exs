defmodule Raxol.Telegram.RichMessageTest do
  use ExUnit.Case, async: true

  import Raxol.Telegram.RichMessage

  alias Raxol.Telegram.RichMessage

  describe "inline builders" do
    test "text/1 produces a plain text leaf" do
      assert text("hi") == %{type: "text", text: "hi"}
    end

    test "bold/1 wraps a string in a single text child" do
      assert bold("hi") == %{type: "bold", children: [%{type: "text", text: "hi"}]}
    end

    test "bold/1 accepts a list of inline children for nesting" do
      assert bold([italic("hi")]) == %{
               type: "bold",
               children: [%{type: "italic", children: [%{type: "text", text: "hi"}]}]
             }
    end

    test "italic, underline, strikethrough, spoiler, subscript, superscript follow the same shape" do
      for {fun, type} <- [
            {&italic/1, "italic"},
            {&underline/1, "underline"},
            {&strikethrough/1, "strikethrough"},
            {&spoiler/1, "spoiler"},
            {&subscript/1, "subscript"},
            {&superscript/1, "superscript"}
          ] do
        assert fun.("x") == %{type: type, children: [%{type: "text", text: "x"}]}
      end
    end

    test "code/1 is a leaf with a text field (no children)" do
      assert code("Enum.map") == %{type: "code", text: "Enum.map"}
    end

    test "math_inline/1 carries an expression field" do
      assert math_inline("x^2") == %{type: "mathematical_inline", expression: "x^2"}
    end
  end

  describe "block builders" do
    test "paragraph/1 with string wraps in text leaf" do
      assert paragraph("hi") == %{
               type: "paragraph",
               children: [%{type: "text", text: "hi"}]
             }
    end

    test "paragraph/1 with inline list passes through" do
      assert paragraph([bold("hi"), text(" world")]) == %{
               type: "paragraph",
               children: [
                 %{type: "bold", children: [%{type: "text", text: "hi"}]},
                 %{type: "text", text: " world"}
               ]
             }
    end

    test "heading/2 enforces level 1-6" do
      assert heading(1, "Title").level == 1
      assert heading(6, "Title").level == 6

      assert_raise FunctionClauseError, fn -> heading(0, "x") end
      assert_raise FunctionClauseError, fn -> heading(7, "x") end
    end

    test "table/1 + cell/1 produce nested rows" do
      tbl =
        table([
          [cell([bold("Header")]), cell([bold("Other")])],
          [cell([text("v1")]), cell([text("v2")])]
        ])

      assert tbl.type == "table"
      assert length(tbl.rows) == 2
      assert hd(hd(tbl.rows)).type == "table_cell"
    end

    test "list/2 defaults to unordered" do
      lst = list([list_item("first"), list_item("second")])
      assert lst.ordered == false
    end

    test "list/2 with ordered: true" do
      lst = list([list_item("one")], ordered: true)
      assert lst.ordered == true
    end

    test "list_item/1 string wraps in a paragraph" do
      item = list_item("hi")
      assert item.type == "list_item"
      assert [%{type: "paragraph"}] = item.children
    end

    test "details/2 has summary and children" do
      d = details([text("Click")], [paragraph("hidden")])
      assert d.type == "details"
      assert d.summary == [%{type: "text", text: "Click"}]
      assert [%{type: "paragraph"}] = d.children
    end

    test "math/1 carries expression" do
      assert math("E=mc^2") == %{type: "mathematical", expression: "E=mc^2"}
    end

    test "thinking/1 wraps blocks" do
      t = thinking([paragraph("reasoning...")])
      assert t.type == "thinking"
      assert [%{type: "paragraph"}] = t.children
    end
  end

  describe "rich_message/1 envelope" do
    test "wraps blocks under :blocks key" do
      msg = rich_message([paragraph("hi")])
      assert msg == %{blocks: [%{type: "paragraph", children: [%{type: "text", text: "hi"}]}]}
    end
  end

  describe "text_length/1" do
    test "text and code leaves count their string length" do
      assert RichMessage.text_length(text("hi")) == 2
      assert RichMessage.text_length(code("ok")) == 2
    end

    test "math expressions count the expression string length" do
      assert RichMessage.text_length(math("x+y")) == 3
      assert RichMessage.text_length(math_inline("x")) == 1
    end

    test "wrapper nodes sum their children" do
      assert RichMessage.text_length(bold([text("ab"), text("cd")])) == 4
      assert RichMessage.text_length(paragraph([bold("abc"), italic("de")])) == 5
    end

    test "table sums all cells across all rows" do
      tbl =
        table([
          [cell([text("ab")]), cell([text("cd")])],
          [cell([text("ef")]), cell([text("gh")])]
        ])

      assert RichMessage.text_length(tbl) == 8
    end

    test "details sums summary + children" do
      d = details([text("hi")], [paragraph("world")])
      assert RichMessage.text_length(d) == 7
    end

    test "list sums all items" do
      l = list([list_item("ab"), list_item("cde")])
      assert RichMessage.text_length(l) == 5
    end

    test "heading sums children" do
      assert RichMessage.text_length(heading(1, "title")) == 5
    end

    test "rich_message envelope sums all blocks" do
      msg = rich_message([paragraph("ab"), paragraph("cde")])
      assert RichMessage.text_length(msg) == 5
    end

    test "unknown nodes count as 0" do
      assert RichMessage.text_length(%{type: "unknown"}) == 0
    end

    test "uses display width (String.length) not byte_size" do
      # CJK chars are multi-byte but single display width
      assert RichMessage.text_length(text("日本語")) == 3
      assert byte_size("日本語") == 9
    end
  end

  describe "chunk/2" do
    test "returns message unchanged when under threshold" do
      msg = rich_message([paragraph("hi")])
      assert {:ok, ^msg} = RichMessage.chunk(msg)
    end

    test "wraps tail in a details block when over threshold" do
      # Three 4000-char paragraphs, threshold 8000
      big = String.duplicate("x", 4000)
      msg = rich_message([paragraph(big), paragraph(big), paragraph(big)])

      assert {:ok, chunked} = RichMessage.chunk(msg, show_more_threshold: 8_000)

      # Head is first two paragraphs; tail wrapped in details
      assert [%{type: "paragraph"}, %{type: "paragraph"}, %{type: "details"} = d] =
               chunked.blocks

      assert d.summary == [%{type: "text", text: "Show more"}]
      assert [%{type: "paragraph"}] = d.children
    end

    test "respects custom :summary text" do
      big = String.duplicate("x", 5_000)
      msg = rich_message([paragraph(big), paragraph(big)])

      assert {:ok, chunked} =
               RichMessage.chunk(msg, show_more_threshold: 4_000, summary: "Read more")

      assert %{type: "details", summary: [%{type: "text", text: "Read more"}]} =
               List.last(chunked.blocks)
    end

    test "returns :too_long when over max_chars" do
      huge = String.duplicate("x", 40_000)
      msg = rich_message([paragraph(huge)])
      assert {:error, :too_long} = RichMessage.chunk(msg, max_chars: 32_768)
    end

    test "respects custom :max_chars" do
      msg = rich_message([paragraph(String.duplicate("x", 100))])
      assert {:error, :too_long} = RichMessage.chunk(msg, max_chars: 50)
    end

    test "single huge block cannot be split, stays in head" do
      # When the first block alone is over threshold, head gets it and tail is empty.
      # Result is unchanged.
      msg = rich_message([paragraph(String.duplicate("x", 10_000))])
      assert {:ok, ^msg} = RichMessage.chunk(msg, show_more_threshold: 8_000, max_chars: 100_000)
    end

    test "boundary lands on whole blocks (no mid-paragraph split)" do
      msg =
        rich_message([
          paragraph(String.duplicate("a", 3_000)),
          paragraph(String.duplicate("b", 3_000)),
          paragraph(String.duplicate("c", 3_000)),
          paragraph(String.duplicate("d", 3_000))
        ])

      assert {:ok, chunked} = RichMessage.chunk(msg, show_more_threshold: 5_000)

      # First block fits in 5000; second crosses; chunker puts first in head,
      # rest in details tail.
      assert [%{type: "paragraph"}, %{type: "details"} = d] = chunked.blocks
      assert length(d.children) == 3
    end
  end

  describe "to_payload/3" do
    test "wraps chat_id and rich_message" do
      msg = rich_message([paragraph("hi")])

      assert RichMessage.to_payload(42, msg) == %{
               chat_id: 42,
               rich_message: msg
             }
    end

    test "passes through reply_markup" do
      msg = rich_message([paragraph("hi")])
      markup = %{inline_keyboard: [[%{text: "Ok", callback_data: "ok"}]]}

      payload = RichMessage.to_payload(42, msg, reply_markup: markup)
      assert payload.reply_markup == markup
    end

    test "passes through disable_notification and reply_to_message_id" do
      msg = rich_message([paragraph("hi")])

      payload =
        RichMessage.to_payload(42, msg,
          disable_notification: true,
          reply_to_message_id: 100
        )

      assert payload.disable_notification == true
      assert payload.reply_to_message_id == 100
    end

    test "drops unknown options silently" do
      msg = rich_message([paragraph("hi")])
      payload = RichMessage.to_payload(42, msg, unknown_option: "x")
      refute Map.has_key?(payload, :unknown_option)
    end

    test "accepts string chat_id (channel @handle form)" do
      msg = rich_message([paragraph("hi")])
      assert %{chat_id: "@channel"} = RichMessage.to_payload("@channel", msg)
    end
  end

  describe "Jason encoding" do
    test "round-trips through JSON without information loss" do
      msg =
        rich_message([
          heading(2, "Title"),
          paragraph([bold("Important: "), text("note")]),
          table([
            [cell([text("a")]), cell([text("b")])],
            [cell([text("c")]), cell([text("d")])]
          ]),
          details([text("Show")], [paragraph("hidden")]),
          math("E=mc^2"),
          list([list_item("first"), list_item("second")], ordered: true)
        ])

      assert {:ok, encoded} = Jason.encode(msg)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded["blocks"] |> length() == 6
      assert hd(decoded["blocks"])["type"] == "heading"
      assert hd(decoded["blocks"])["level"] == 2
    end
  end

  describe "constants" do
    test "max_chars/0 is 32768" do
      assert RichMessage.max_chars() == 32_768
    end

    test "show_more_threshold/0 is 8000" do
      assert RichMessage.show_more_threshold() == 8_000
    end
  end
end
