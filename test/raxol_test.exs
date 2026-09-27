defmodule RaxolTest do
  # set_theme/1 writes the application env, which is global.
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.UI.Theming.Theme

  defmodule ThemedApp do
    @moduledoc false
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model), do: Raxol.Core.Renderer.View.text("Themed")

    @impl true
    def subscriptions(_model), do: []
  end

  @env_keys [:theme, :current_theme, :themes, :high_contrast_restore]

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

  describe "set_theme/1 in a running app" do
    setup do
      pid =
        case Process.whereis(Headless) do
          nil -> start_supervised!({Headless, [name: Headless]})
          existing -> existing
        end

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.call(pid, {:stop_session, :raxol_test_themed_app}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "the next frame renders with the new theme" do
      {:ok, id} =
        Headless.start(ThemedApp,
          id: :raxol_test_themed_app,
          width: 20,
          height: 3
        )

      {:ok, before} = Headless.get_buffer(id)
      refute foreground_at(before, 0, 0) == :magenta

      :ok =
        Raxol.set_theme(
          Theme.new(%{
            id: :raxol_test_render_theme,
            name: "Raxol Test Render Theme",
            colors: %{foreground: :magenta}
          })
        )

      {:ok, after_set} = Headless.get_buffer(id)
      assert foreground_at(after_set, 0, 0) == :magenta
    end

    # Registering a theme under the default id is how an app replaces the
    # built-in default; frames render it until set_theme/1 picks another.
    test "a theme registered under the default id renders before any set_theme/1" do
      Application.delete_env(:raxol, :current_theme)

      :ok =
        Theme.register(
          Theme.new(%{
            id: Theme.default_theme_id(),
            name: "Raxol Test Registered Default",
            colors: %{foreground: :cyan}
          })
        )

      {:ok, id} =
        Headless.start(ThemedApp,
          id: :raxol_test_themed_app,
          width: 20,
          height: 3
        )

      {:ok, buffer} = Headless.get_buffer(id)
      assert foreground_at(buffer, 0, 0) == :cyan
    end
  end

  defp foreground_at(buffer, x, y),
    do:
      buffer.cells
      |> Enum.at(y)
      |> Enum.at(x)
      |> Map.fetch!(:style)
      |> Map.fetch!(:foreground)

  describe "set_accessibility/1" do
    test "options other than :high_contrast leave the theme alone", %{
      theme: theme
    } do
      :ok = Raxol.set_theme(theme)

      assert :ok = Raxol.set_accessibility(screen_reader: true)
      assert :ok = Raxol.set_accessibility(reduced_motion: false)

      assert Theme.current() == theme
    end

    test "high_contrast raises the current theme's contrast and turning it off restores it",
         %{theme: theme} do
      :ok = Raxol.set_theme(theme)
      high_contrast = Theme.adjust_for_high_contrast(theme)
      refute high_contrast == theme

      assert :ok = Raxol.set_accessibility(high_contrast: true)
      assert Theme.current() == high_contrast

      assert :ok = Raxol.set_accessibility(high_contrast: true)
      assert Theme.current() == high_contrast

      assert :ok = Raxol.set_accessibility(high_contrast: false)
      assert Theme.current() == theme
    end

    test "turning high_contrast off keeps a theme set while it was on", %{
      theme: theme
    } do
      :ok = Raxol.set_accessibility(high_contrast: true)
      :ok = Raxol.set_theme(theme)

      assert :ok = Raxol.set_accessibility(high_contrast: false)
      assert Theme.current() == theme
    end

    test "high_contrast works on a theme whose colours are not RGB" do
      theme =
        Theme.new(%{id: :custom, name: "Custom", colors: %{primary: :green}})

      :ok = Raxol.set_theme(theme)

      assert :ok = Raxol.set_accessibility(high_contrast: true)
      assert Theme.current().colors.primary == :green

      assert :ok = Raxol.set_accessibility(high_contrast: false)
      assert Theme.current() == theme
    end

    test "turning high_contrast on again raises the contrast of a theme set meanwhile",
         %{theme: theme} do
      :ok = Raxol.set_accessibility(high_contrast: true)
      :ok = Raxol.set_theme(theme)

      assert :ok = Raxol.set_accessibility(high_contrast: true)
      assert Theme.current() == Theme.adjust_for_high_contrast(theme)

      assert :ok = Raxol.set_accessibility(high_contrast: false)
      assert Theme.current() == theme
    end
  end
end
