defmodule Raxol.Terminal.Driver.BackgroundQueryTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Driver.BackgroundQuery

  describe "scan/1" do
    test "extracts a BEL-terminated 16-bit reply" do
      {result, cleaned} = BackgroundQuery.scan("\e]11;rgb:2b2b/2b2b/2b2b\a")
      assert result == {:ok, {43, 43, 43}}
      assert cleaned == ""
    end

    test "extracts an ST-terminated reply" do
      {result, cleaned} = BackgroundQuery.scan("\e]11;rgb:ffff/0000/8080\e\\")
      assert result == {:ok, {255, 0, 128}}
      assert cleaned == ""
    end

    test "preserves surrounding keystrokes in order" do
      {result, cleaned} = BackgroundQuery.scan("ab\e]11;rgb:00/00/00\acd")
      assert result == {:ok, {0, 0, 0}}
      assert cleaned == "abcd"
    end

    test "strips the DA probe reply alongside the color reply" do
      {result, cleaned} =
        BackgroundQuery.scan("\e]11;rgb:1e1e/1e1e/1e1e\a\e[?62;22c" <> "x")

      assert result == {:ok, {30, 30, 30}}
      assert cleaned == "x"
    end

    test "DA reply without color reply means unsupported" do
      {result, cleaned} = BackgroundQuery.scan("q\e[?1;2cw")
      assert result == :unsupported
      assert cleaned == "qw"
    end

    test "no reply at all stays pending, data untouched" do
      {result, cleaned} = BackgroundQuery.scan("hello\e[A")
      assert result == :pending
      assert cleaned == "hello\e[A"
    end

    test "8-bit channels scale correctly" do
      {result, _} = BackgroundQuery.scan("\e]11;rgb:2b/2b/2b\a")
      assert result == {:ok, {43, 43, 43}}
    end

    test "rgba payload drops alpha" do
      {result, _} = BackgroundQuery.scan("\e]11;rgba:ffff/8080/0000/ffff\a")
      assert result == {:ok, {255, 128, 0}}
    end

    test "hash-hex payload parses" do
      {result, _} = BackgroundQuery.scan("\e]11;#1a1a2e\a")
      assert result == {:ok, {26, 26, 46}}
    end

    test "malformed payload reports unsupported, reply still stripped" do
      {result, cleaned} = BackgroundQuery.scan("\e]11;banana\aok")
      assert result == :unsupported
      assert cleaned == "ok"
    end
  end

  describe "parse_color/1 channel widths" do
    test "scales 1, 2, 3 and 4 digit channels to 8-bit" do
      assert BackgroundQuery.parse_color("rgb:f/f/f") == {:ok, {255, 255, 255}}

      assert BackgroundQuery.parse_color("rgb:80/80/80") ==
               {:ok, {128, 128, 128}}

      assert BackgroundQuery.parse_color("rgb:fff/fff/fff") ==
               {:ok, {255, 255, 255}}

      assert BackgroundQuery.parse_color("rgb:8000/8000/8000") ==
               {:ok, {128, 128, 128}}
    end
  end

  describe "store/detect" do
    test "round-trips through persistent_term" do
      assert BackgroundQuery.store({43, 43, 43}) == :ok
      assert BackgroundQuery.detected_background() == {:ok, {43, 43, 43}}
    end
  end

  describe "parse_color/1 hex" do
    test "parses a valid 6-digit hex" do
      assert BackgroundQuery.parse_color("#1a1a2e") == {:ok, {26, 26, 46}}
    end

    test "returns :error for invalid hex digits" do
      assert BackgroundQuery.parse_color("#zzzzzz") == :error
    end

    test "returns :error for a 5-length hex (guard rejects)" do
      assert BackgroundQuery.parse_color("#12345") == :error
    end

    test "returns :error for a 7-length hex (guard rejects)" do
      assert BackgroundQuery.parse_color("#1234567") == :error
    end
  end
end
