defmodule Raxol.Agent.ClientProtocol.RawInputTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.RawInput

  # Room for the budget itself plus the JSON punctuation around what it buys.
  @wire_bound 12_000

  defp encoded_size(params), do: params |> RawInput.render() |> Jason.encode!() |> byte_size()

  test "JSON values come through unchanged" do
    params = %{"amount" => 5, "to" => "bob", "fee" => 0.5, "ok" => true, "memo" => nil}

    assert RawInput.render(params) == params
    assert RawInput.render(%{"list" => [1, "two", [3]]}) == %{"list" => [1, "two", [3]]}
  end

  test "atom keys and atom values become strings" do
    assert RawInput.render(%{amount: 5, mode: :fast}) == %{"amount" => 5, "mode" => "fast"}
  end

  test "what JSON has no form for is shown by inspect" do
    assert RawInput.render(%{"at" => {1, 2}}) == %{"at" => "{1, 2}"}
    assert RawInput.render(%{"range" => 1..3}) == %{"range" => "1..3"}
    assert RawInput.render(%{"bytes" => <<0xFF, 0xFE>>}) == %{"bytes" => "<<255, 254>>"}
    assert RawInput.render(%{{:a, 1} => 1}) == %{"{:a, 1}" => 1}
    assert RawInput.render([1 | 2]) == "[1 | 2]"
    assert %{"pid" => "#PID<" <> _} = RawInput.render(%{"pid" => self()})
  end

  test "a map nested past the depth bound is shown by inspect" do
    params = %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => 1}}}}}

    assert RawInput.render(params) == %{"a" => %{"b" => %{"c" => %{"d" => ~s(%{"e" => 1})}}}}
  end

  test "a long string is cut on a character boundary and marked" do
    rendered = RawInput.render(%{"text" => String.duplicate("é", 100_000)})

    assert String.valid?(rendered["text"])
    assert String.ends_with?(rendered["text"], "...")
    assert byte_size(rendered["text"]) < @wire_bound
  end

  test "what is left of a list or a map once the budget is spent is replaced by a mark" do
    assert "..." = List.last(RawInput.render(Enum.to_list(1..100_000)))
    assert %{"..." => "..."} = RawInput.render(Map.new(1..100_000, &{"key#{&1}", &1}))
  end

  test "the copy is bounded whatever the params" do
    deep = Enum.reduce(1..1_000, 1, fn _level, inner -> %{"in" => [inner]} end)
    wide = Map.new(1..10_000, &{"key#{&1}", String.duplicate("v", 1_000)})

    for params <- [
          String.duplicate("x", 1_000_000),
          Enum.to_list(1..100_000),
          List.duplicate(String.duplicate("y", 10_000), 1_000),
          List.duplicate(self(), 10_000),
          wide,
          deep
        ] do
      assert encoded_size(params) < @wire_bound
    end
  end
end
