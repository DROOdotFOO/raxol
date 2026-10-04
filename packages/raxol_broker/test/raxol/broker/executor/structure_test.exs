defmodule Raxol.Broker.Executor.StructureTest do
  @moduledoc """
  The write path's shape, checked from compiled code rather than source
  text: every remote call in every module of `:raxol_broker` is read from
  its BEAM debug info (Erlang abstract forms), so an alias, an import or a
  capture cannot hide a call the way it hides from a regex.

  The one text check left is for order-writing tool names: a string literal
  (or a fragment of one after an interpolation) beginning `place_`,
  `cancel_` or `replace_` may appear only in `executor/place.ex`.
  """
  use ExUnit.Case, async: true

  @port Raxol.Broker.Executor.Port
  @port_mcp Raxol.Broker.Executor.Port.MCP
  @upstream Raxol.MCP.Client

  setup_all do
    {:ok, calls: Enum.flat_map(broker_modules(), &remote_calls/1)}
  end

  defp broker_modules do
    _ = Application.load(:raxol_broker)
    {:ok, modules} = :application.get_key(:raxol_broker, :modules)
    assert @port_mcp in modules
    modules
  end

  # `{caller, {module, function, arity}}` for each remote call or remote
  # capture in `module`'s abstract code.
  defp remote_calls(module) do
    {^module, beam, _path} = :code.get_object_code(module)

    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    forms |> collect([]) |> Enum.map(&{module, &1})
  end

  defp collect({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args} = node, acc),
    do: collect(Tuple.to_list(node), [{m, f, length(args)} | acc])

  defp collect({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc),
    do: [{m, f, a} | acc]

  defp collect(node, acc) when is_tuple(node), do: collect(Tuple.to_list(node), acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_leaf, acc), do: acc

  defp callers(calls, fun) do
    for {caller, mfa} <- calls, fun.(mfa), uniq: true, do: caller
  end

  test "the walker sees remote calls (sanity)", %{calls: calls} do
    assert {Raxol.Broker.Executor.Place, {Raxol.Broker.Journal, :append_to_group, 3}} in calls
  end

  test "only Review and Place call Port.call/4", %{calls: calls} do
    assert Enum.sort(callers(calls, &match?({@port, :call, 4}, &1))) ==
             Enum.sort([Raxol.Broker.Executor.Place, Raxol.Broker.Executor.Review])
  end

  test "nothing calls Port.MCP.call/4 directly; it is reached only through Port", %{calls: calls} do
    assert callers(calls, &match?({@port_mcp, :call, _}, &1)) == []
  end

  test "only Port.MCP and the read-only broker client call Raxol.MCP.Client.call_tool",
       %{calls: calls} do
    callers = callers(calls, &match?({@upstream, :call_tool, _}, &1))
    assert @port_mcp in callers
    assert callers -- [@port_mcp, Raxol.Broker.MCP.Client] == []
  end

  @order_literal ~r/(["'}]|~[a-zA-Z].)(place|cancel|replace)_/

  test "no order-writing tool name is spelled outside executor/place.ex" do
    lib = Path.expand("../../../../lib", __DIR__)
    place = Path.join(lib, "raxol/broker/executor/place.ex")
    files = Path.wildcard(Path.join(lib, "**/*.ex"))
    assert place in files

    offenders =
      for file <- files -- [place],
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@order_literal, line),
          do: "#{Path.relative_to(file, lib)}:#{number}: #{String.trim(line)}"

    assert offenders == []
  end

  test "the literal check catches the spellings it is meant to" do
    for source <- [
          ~S|"place_equity_order"|,
          ~S|"cancel_" <> kind|,
          ~S|"#{verb}replace_order"|,
          ~S|~s(place_order)|,
          ~S|'cancel_order'|
        ] do
      assert Regex.match?(@order_literal, source), source
    end

    refute Regex.match?(@order_literal, ~S|:place_timeout|)
  end
end
