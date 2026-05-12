defmodule Raxol.MCP.Test.Assertions do
  @moduledoc """
  ExUnit assertion macros for Raxol MCP tests.

  All assertions are pipe-friendly -- they return the session on success,
  so you can chain them:

      session
      |> click("btn")
      |> assert_tool_available("btn.click")
      |> assert_component("status", fn c -> c[:content] == "done" end)

  ## Usage

      use ExUnit.Case
      import Raxol.MCP.Test
      import Raxol.MCP.Test.Assertions
  """

  alias Raxol.MCP.Test

  @doc """
  Asserts a Component with the given ID exists in the current view tree.

  Optionally takes a predicate function to check Component properties.

      assert_component(session, "search_input")
      assert_component(session, "counter", fn c -> c[:content] == "5" end)
  """
  defmacro assert_component(session, component_id, predicate \\ nil) do
    predicate_check =
      if predicate do
        quote do
          predicate_fn = unquote(predicate)

          ExUnit.Assertions.assert(
            predicate_fn.(component),
            "Component '#{component_id}' did not match predicate. Component: #{inspect(component)}"
          )
        end
      end

    quote do
      session = unquote(session)
      component_id = unquote(component_id)
      component = Test.get_component(session, component_id)

      ExUnit.Assertions.assert(
        component != nil,
        "Expected Component '#{component_id}' to exist in view tree, but it was not found. " <>
          "Components: #{inspect(Test.get_structured_components(session) |> collect_ids())}"
      )

      unquote(predicate_check)

      session
    end
  end

  @doc """
  Asserts a Component with the given ID does NOT exist in the view tree.

      refute_component(session, "deleted_item")
  """
  defmacro refute_component(session, component_id) do
    quote do
      session = unquote(session)
      component_id = unquote(component_id)
      component = Test.get_component(session, component_id)

      ExUnit.Assertions.refute(
        component != nil,
        "Expected Component '#{component_id}' not to exist, but found: #{inspect(component)}"
      )

      session
    end
  end

  @doc """
  Asserts a tool with the given name is available in the MCP registry.

      assert_tool_available(session, "search_input.type_into")
  """
  defmacro assert_tool_available(session, tool_name) do
    quote do
      session = unquote(session)
      tool_name = unquote(tool_name)
      tools = Test.get_tools(session)
      names = Enum.map(tools, & &1[:name])

      ExUnit.Assertions.assert(
        tool_name in names,
        "Expected tool '#{tool_name}' to be available. " <>
          "Registered tools: #{inspect(names)}"
      )

      session
    end
  end

  @doc """
  Asserts a tool is NOT available in the MCP registry.

      refute_tool_available(session, "disabled_btn.click")
  """
  defmacro refute_tool_available(session, tool_name) do
    quote do
      session = unquote(session)
      tool_name = unquote(tool_name)
      tools = Test.get_tools(session)
      names = Enum.map(tools, & &1[:name])

      ExUnit.Assertions.refute(
        tool_name in names,
        "Expected tool '#{tool_name}' not to be available, but it was found."
      )

      session
    end
  end

  @doc """
  Asserts the model matches a predicate function.

      assert_model(session, fn model -> model.count == 5 end)
  """
  defmacro assert_model(session, predicate) do
    quote do
      session = unquote(session)
      model = Test.get_model(session)

      ExUnit.Assertions.assert(
        unquote(predicate).(model),
        "Model did not match predicate. Model: #{inspect(model)}"
      )

      session
    end
  end

  @doc """
  Asserts the text screenshot contains the given string.

      assert_screenshot_contains(session, "Welcome")
  """
  defmacro assert_screenshot_contains(session, text) do
    quote do
      session = unquote(session)
      screenshot = Test.screenshot(session)

      ExUnit.Assertions.assert(
        String.contains?(screenshot, unquote(text)),
        "Expected screenshot to contain #{inspect(unquote(text))}.\n" <>
          "Screenshot:\n#{screenshot}"
      )

      session
    end
  end

  @doc """
  Asserts the structured Component tree matches an expected shape.

  The expected value is a list of maps with `:type` and optionally `:id`.
  Uses subset matching -- each expected Component must appear somewhere
  in the actual tree.

      assert_screenshot_matches(session, [
        %{type: :button, id: "submit"},
        %{type: :text_input, id: "name"}
      ])
  """
  defmacro assert_screenshot_matches(session, expected) do
    quote do
      session = unquote(session)
      actual = Test.get_structured_components(session)
      expected = unquote(expected)

      for expected_component <- expected do
        found =
          find_matching_component(
            actual,
            expected_component[:type],
            expected_component[:id]
          )

        ExUnit.Assertions.assert(
          found != nil,
          "Expected Component #{inspect(expected_component)} not found in tree. " <>
            "Actual: #{inspect(actual)}"
        )
      end

      session
    end
  end

  @doc """
  Asserts that exactly N tools are registered.

      assert_tool_count(session, 5)
  """
  defmacro assert_tool_count(session, count) do
    quote do
      session = unquote(session)
      tools = Test.get_tools(session)
      actual_count = length(tools)
      expected = unquote(count)

      ExUnit.Assertions.assert(
        actual_count == expected,
        "Expected #{expected} tools, got #{actual_count}. " <>
          "Tools: #{inspect(Enum.map(tools, & &1[:name]))}"
      )

      session
    end
  end

  # -- Helper functions (not macros, used inside macro expansions) -------------

  @doc false
  def find_matching_component(components, type, id) when is_list(components) do
    Enum.find_value(components, fn component ->
      type_matches = type == nil or component[:type] == type
      id_matches = id == nil or to_string(component[:id]) == to_string(id)

      cond do
        type_matches and id_matches ->
          component

        is_list(component[:children]) ->
          find_matching_component(component[:children], type, id)

        true ->
          nil
      end
    end)
  end

  def find_matching_component(_, _, _), do: nil

  @doc false
  def collect_ids(components) when is_list(components) do
    Enum.flat_map(components, fn component ->
      own = if component[:id], do: [component[:id]], else: []
      children = collect_ids(component[:children] || [])
      own ++ children
    end)
  end

  def collect_ids(_), do: []
end
