defmodule Raxol.UI.Theming.SelectorTest do
  # Selecting a theme applies it through the application env, which is global.
  use ExUnit.Case, async: false

  alias Raxol.UI.Theming.Selector
  alias Raxol.UI.Theming.Theme

  @env_keys [:current_theme, :themes]

  setup do
    saved = Map.new(@env_keys, &{&1, Application.fetch_env(:raxol, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:raxol, key, value)
        {key, :error} -> Application.delete_env(:raxol, key)
      end)
    end)

    theme =
      Theme.new(%{
        id: :selector_test_theme,
        name: "Selector Test Theme",
        colors: %{foreground: "#123456"}
      })

    :ok = Theme.register(theme)

    %{theme: theme}
  end

  # A click on the collapsed selector opens its list; the list draws the
  # header on row 0 and theme `i` on row `i + 1`.
  defp click_theme(theme, props \\ %{}) do
    selector = Selector.init(props)

    {:ok, opened} =
      Selector.handle_event(selector, {:mouse_event, :click, 0, 0, :left}, %{})

    assert opened.state.expanded

    index = Enum.find_index(opened.state.themes, &(&1.id == theme.id))

    Selector.handle_event(
      opened,
      {:mouse_event, :click, 2, index + 1, :left},
      %{}
    )
  end

  test "clicking a theme in the list applies it and closes the list", %{
    theme: theme
  } do
    assert {:ok, selected} = click_theme(theme)

    assert Theme.current() == theme
    refute selected.state.expanded
  end

  test "clicking a theme calls on_select with its name", %{theme: theme} do
    test_pid = self()

    {:ok, _selected} =
      click_theme(theme, %{on_select: &send(test_pid, {:selected, &1})})

    assert_received {:selected, "Selector Test Theme"}
  end
end
