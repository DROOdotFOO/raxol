defmodule RaxolPlaygroundWeb.FrameTransportTest do
  @moduledoc """
  The prerecorded gallery cards ship a transport, and each transport has to
  address the recording it sits under: a slider whose `max` is off by one
  silently makes the last frame unreachable, and a slider on a single-frame
  still is a control that cannot do anything.

  Asserted against the rendered document rather than the markup source,
  because the range is emitted conditionally and it is the emitted `max` that
  a reader drags.
  """
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias Raxol.Playground.Catalog
  alias RaxolPlayground.RecordedFrames

  @endpoint RaxolPlaygroundWeb.Endpoint

  # Every catalog demo that has a committed preview, with its frame count.
  # Derived rather than named, so regenerating the previews cannot leave this
  # asserting against a demo that no longer animates.
  defp previews do
    for component <- Catalog.list_components(),
        preview = RecordedFrames.preview(component.name),
        do: {component.name, length(preview.frames)}
  end

  defp gallery_html do
    build_conn() |> get("/gallery") |> html_response(200)
  end

  # There is no HTML parser in this project's dependencies, so one card is cut
  # out of the page by its own id. Its picture and transport run from that id to
  # the card's text body, which is the next thing rendered either way, and the
  # slice is what makes "this card has a scrub bar" distinguishable from "some
  # card on the page does".
  defp card_html(html, name) do
    marker = ~s(id="preview-#{RecordedFrames.slug(name)}")

    case String.split(html, marker, parts: 2) do
      [_, rest] -> rest |> String.split(~s(<div class="p-3), parts: 2) |> hd()
      [_] -> flunk("no preview rendered for #{name}")
    end
  end

  test "an animated card's scrub bar addresses every frame of its recording" do
    {name, count} =
      Enum.find(previews(), fn {_name, count} -> count > 1 end) ||
        flunk("no catalog demo has a multi-frame preview to scrub")

    card = card_html(gallery_html(), name)

    assert card =~ ~s(type="range")
    assert card =~ ~s(data-role="player-seek")
    assert card =~ ~s(min="0")
    assert card =~ ~s(max="#{count - 1}")
    assert card =~ ~s(step="1")
    assert card =~ ~s(data-role="player-toggle")

    # The slider's value is an array offset, so the announced value is a
    # sentence rather than the number.
    assert card =~ ~s(aria-label="Scrub the #{name} recording")
    assert card =~ ~s(aria-valuetext="frame 1 of #{count}")
  end

  test "a single-frame card gets no transport at all" do
    {name, 1} =
      Enum.find(previews(), fn {_name, count} -> count == 1 end) ||
        flunk("no catalog demo has a single-frame preview")

    card = card_html(gallery_html(), name)

    assert card =~ "gallery-preview"
    refute card =~ ~s(data-role="player-seek")
    refute card =~ ~s(data-role="player-toggle")
    refute card =~ "card-transport"
  end

  test "each gallery card exposes one card-wide demo link" do
    html = gallery_html()

    for component <- Catalog.list_components() do
      destination = ~s(href="/demos/#{component.name}")

      assert length(:binary.matches(html, destination)) == 1,
             "#{component.name} should expose one demo link across its card"
    end

    refute html =~ ">open →</a>"
  end
end
