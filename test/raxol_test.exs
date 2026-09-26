defmodule RaxolTest do
  # set_theme/1 writes the application env, which is global.
  use ExUnit.Case, async: false

  alias Raxol.UI.Theming.Theme

  @env_keys [:theme, :current_theme, :themes]

  setup do
    saved = Map.new(@env_keys, &{&1, Application.fetch_env(:raxol, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:raxol, key, value)
        {key, :error} -> Application.delete_env(:raxol, key)
      end)
    end)

    banner = Raxol.Style.new(text_decoration: [:bold])

    theme =
      Theme.new(%{
        id: :raxol_test_theme,
        name: "Raxol Test Theme",
        colors: %{foreground: "#123456"},
        component_styles: %{banner: banner}
      })

    %{theme: theme, banner: banner}
  end

  describe "set_theme/1" do
    test "a theme struct becomes the theme renderers read", %{
      theme: theme,
      banner: banner
    } do
      assert :ok = Raxol.set_theme(theme)

      assert Theme.current() == theme
      assert Raxol.current_theme() == theme
      assert Raxol.Style.resolve(:banner) == banner
    end

    test "a registered theme name applies that theme", %{theme: theme} do
      :ok = Theme.register(theme)

      assert :ok = Raxol.set_theme(:raxol_test_theme)

      assert Theme.current() == theme
      assert Raxol.current_theme() == theme
    end

    test "an unknown theme name is an error and leaves the theme alone", %{
      theme: theme
    } do
      :ok = Raxol.set_theme(theme)

      assert {:error, :theme_not_found} = Raxol.set_theme(:no_such_theme)

      assert Theme.current() == theme
      assert Raxol.current_theme() == theme
    end
  end
end
