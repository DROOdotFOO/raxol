defmodule Raxol.Harness.EditorSurfaceTest do
  @moduledoc """
  `Raxol.Harness.Surface` + the `:edit_draft` command: the Ctrl+E chord
  dispatched through the real keymap-first `handle_input/2` path with a
  STUB editor session injected. Asserts the model-side contract (draft
  replaced / kept, notices, geometry update) and the byte-side contract
  (the re-pin + full footer keyframe on resume). StringIO only.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface
  alias Raxol.UI.Components.Harness.Composer

  defp open_device, do: StringIO.open("") |> elem(1)

  defp flush(device), do: StringIO.flush(device)

  defp new_surface(device, opts \\ []) do
    Surface.new(
      [],
      Keyword.merge(
        [
          device: device,
          width: 80,
          rows: 24,
          footer_rows: 6,
          mode: :inline_log
        ],
        opts
      )
    )
  end

  defp ctrl_e, do: Event.key_event("e", :pressed, [:ctrl])

  defp with_draft(model, text),
    do: %{model | composer: Composer.set_value(model.composer, text)}

  test "the session receives the composer's current draft" do
    device = open_device()
    parent = self()

    session = fn draft, opts ->
      send(parent, {:session_called, draft, opts})
      {:ok, %{text: draft, width: 80, rows: 24}}
    end

    model =
      device |> new_surface(editor_session: session) |> with_draft("my draft")

    _model = Surface.handle_input(model, ctrl_e())

    assert_received {:session_called, "my draft", opts}
    assert opts[:rows] == 24
    assert opts[:width] == 80
    # the device threaded to the session is the authority's own
    assert opts[:device] == device
  end

  test "{:ok, text} replaces the composer draft and the footer keyframe carries it" do
    device = open_device()

    session = fn _draft, _opts ->
      {:ok, %{text: "edited in vim", width: 80, rows: 24}}
    end

    model =
      device |> new_surface(editor_session: session) |> with_draft("before")

    _ = flush(device)
    model = Surface.handle_input(model, ctrl_e())

    assert Composer.value(model.composer) == "edited in vim"

    bytes = flush(device)
    # the resume re-pin (geometry unchanged -- only reassert emits it)
    assert bytes =~ "\e[1;18r"
    # the promoted keyframe re-rendered the composer with the new text
    assert bytes =~ "edited in vim"
  end

  test "{:kept, reason, geo} keeps the original draft and shows a one-frame notice" do
    device = open_device()

    session = fn _draft, _opts ->
      {:kept, :editor_nonzero, %{width: 80, rows: 24}}
    end

    model =
      device |> new_surface(editor_session: session) |> with_draft("original")

    _ = flush(device)
    model = Surface.handle_input(model, ctrl_e())

    assert Composer.value(model.composer) == "original"

    bytes = flush(device)
    assert bytes =~ "draft kept"
    assert bytes =~ "\e[1;18r"

    # one-frame: the notice is consumed by the paint that rendered it
    assert model.stub_notice == nil
  end

  test "{:error, reason} shows the abort notice and STILL re-pins (belt-and-braces)" do
    device = open_device()

    session = fn _draft, _opts -> {:error, {:reader_disable, :timeout}} end

    model = new_surface(device, editor_session: session)
    _ = flush(device)
    model = Surface.handle_input(model, ctrl_e())

    bytes = flush(device)
    assert bytes =~ "editor suspend aborted"
    assert bytes =~ "\e[1;18r"
    assert Composer.value(model.composer) == ""
  end

  test "a raising session degrades to the abort notice -- the UI loop survives" do
    device = open_device()

    session = fn _draft, _opts -> raise "session exploded" end

    model = new_surface(device, editor_session: session)
    _ = flush(device)
    model = Surface.handle_input(model, ctrl_e())

    bytes = flush(device)
    assert bytes =~ "editor suspend aborted"
    assert model.stub_notice == nil
  end

  test "geometry changed while suspended: model + pin track the session's re-queried size" do
    device = open_device()

    session = fn _draft, _opts ->
      {:ok, %{text: "t", width: 100, rows: 30}}
    end

    model = new_surface(device, editor_session: session)
    _ = flush(device)
    model = Surface.handle_input(model, ctrl_e())

    assert model.width == 100
    assert model.rows == 30
    # the pin is at the NEW split (30 rows - 6 footer)
    assert flush(device) =~ "\e[1;24r"
  end

  test "no session wired: honest stub notice, no crash" do
    device = open_device()
    model = new_surface(device)
    _ = flush(device)
    _model = Surface.handle_input(model, ctrl_e())

    assert flush(device) =~ "external editor not wired"
  end

  test "flat mode: seals one honest history line (no footer composer to edit into)" do
    device = open_device()

    model =
      new_surface(device,
        mode: :flat,
        editor_session: fn _draft, _opts -> flunk("must not be called") end
      )

    _ = flush(device)
    _model = Surface.handle_input(model, ctrl_e())

    bytes = flush(device)
    assert bytes =~ "external editor requires the footer composer"
    assert String.ends_with?(bytes, "\n")
  end
end
