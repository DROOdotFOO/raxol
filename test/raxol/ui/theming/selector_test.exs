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

  defp key(selector, key),
    do: Selector.handle_event(selector, {:key_press, key, []}, %{})

  # Opens the list from the keyboard and moves the highlight onto `theme`.
  defp highlight_with_keys(theme, props \\ %{}) do
    {:ok, opened} = key(Selector.init(props), :enter)
    assert opened.state.expanded

    target = Enum.find_index(opened.state.themes, &(&1.id == theme.id))
    steps = target - opened.state.selected_index
    arrow = if steps < 0, do: :up, else: :down

    Enum.reduce(List.duplicate(arrow, abs(steps)), opened, fn arrow, selector ->
      {:ok, moved} = key(selector, arrow)
      moved
    end)
  end

  test "Enter on the closed selector opens the list and leaves the theme alone" do
    before = Theme.current()

    assert {:ok, opened} = key(Selector.init(%{}), :enter)

    assert opened.state.expanded
    assert Theme.current() == before
  end

  # A click can only land on a listed theme; Enter picks the highlight,
  # which an empty list does not have.
  test "Enter on an empty list closes it and leaves the theme alone" do
    Application.put_env(:raxol, :themes, %{})
    before = Theme.current()

    {:ok, opened} = key(Selector.init(%{}), :enter)
    assert opened.state.themes == []

    assert {:ok, closed} = key(opened, :enter)

    refute closed.state.expanded
    assert Theme.current() == before
  end

  for select_key <- [:enter, :space] do
    test "#{select_key} applies the highlighted theme, closes the list and calls on_select",
         %{theme: theme} do
      test_pid = self()

      highlighted =
        highlight_with_keys(theme, %{
          on_select: &send(test_pid, {:selected, &1})
        })

      assert {:ok, selected} = key(highlighted, unquote(select_key))

      assert Theme.current() == theme
      refute selected.state.expanded
      assert_received {:selected, "Selector Test Theme"}
    end
  end

  test "Escape closes the list without applying the highlighted theme", %{
    theme: theme
  } do
    before = Theme.current()
    highlighted = highlight_with_keys(theme)

    assert {:ok, closed} = key(highlighted, :escape)

    refute closed.state.expanded
    assert Theme.current() == before
  end
end
