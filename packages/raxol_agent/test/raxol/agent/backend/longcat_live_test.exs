defmodule Raxol.Agent.Backend.LongCatLiveTest do
  @moduledoc """
  Live gate: resolve the `:longcat` harness and drive the real LongCat API
  (Meituan, `https://api.longcat.chat/openai`, model `LongCat-2.0`) through
  `Backend.HTTP.complete/2` and `stream/2`.

  Tagged `:live_longcat`; excluded by default and compiled only when
  `LONGCAT_API_KEY` is present, so CI and offline runs never touch the network:

      LONGCAT_API_KEY=<key> mix test --only live_longcat \\
        test/raxol/agent/backend/longcat_live_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :live_longcat

  if System.get_env("LONGCAT_API_KEY") do
    alias Raxol.Agent.Backend.HTTP
    alias Raxol.Agent.Backend.Selector
    alias Raxol.Agent.ExecutorConfig

    @prompt [%{role: :user, content: "Reply with exactly the word: pong"}]

    setup do
      {:ok, %{key: System.get_env("LONGCAT_API_KEY")}}
    end

    # Resolve the :longcat harness exactly as production would, folding in the key.
    defp longcat_opts(key) do
      cfg = ExecutorConfig.new(harness: :longcat, auth: %{api_key: key})
      {:ok, HTTP, opts} = Selector.select(cfg)
      opts
    end

    defp no_raw_map!(text) do
      refute text =~ "%{", "content must not contain a raw Elixir map: #{inspect(text)}"
      refute text =~ "=>", "content must not contain map arrows: #{inspect(text)}"
      text
    end

    test "complete/2 returns non-empty content with no raw-map leak", %{key: key} do
      assert {:ok, response} = HTTP.complete(@prompt, longcat_opts(key))

      assert is_binary(response.content)
      assert String.trim(response.content) != ""
      no_raw_map!(response.content)
      assert response.metadata.provider == :openai
    end

    test "stream/2 yields chunks and a final :done with accumulated content", %{key: key} do
      assert {:ok, stream} = HTTP.stream(@prompt, longcat_opts(key))
      events = Enum.to_list(stream)

      refute Enum.any?(events, &match?({:error, _}, &1)),
             "stream errored: #{inspect(events)}"

      assert {:done, done} = List.last(events)
      assert is_binary(done.content)
      assert String.trim(done.content) != ""
      no_raw_map!(done.content)
    end
  end
end
