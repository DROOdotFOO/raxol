defmodule Raxol.LiveView.TEALiveTest do
  use ExUnit.Case, async: true

  alias Raxol.LiveView.TEALive

  describe "announcement live region" do
    test "handle_info stores the latest announcement in the assign" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, announcement: nil}
      }

      msg =
        {:announcement_added, make_ref(),
         %{message: "Saved", priority: :normal, interrupt: false, timestamp: 0}}

      assert {:noreply, socket} = TEALive.handle_info(msg, socket)
      assert socket.assigns.announcement == %{message: "Saved", priority: :normal}
    end

    test "renders a polite sr-only region for normal announcements" do
      html = render_html(%{message: "Saved", priority: :normal})

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ "Saved"
    end

    test "renders an assertive sr-only region for high-priority announcements" do
      html = render_html(%{message: "Danger", priority: :high})

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(aria-live="assertive")
      assert html =~ "Danger"
    end

    test "renders an always-present polite region when there is no announcement" do
      html = render_html(nil)

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(aria-live="polite")
    end

    defp render_html(announcement) do
      assigns = %{
        __changed__: nil,
        terminal_html: "",
        announcement: announcement,
        animation_css: nil
      }

      TEALive.render(assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    end
  end
end
