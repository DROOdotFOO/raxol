# Frame bytes of older releases on today's scoreboard screens.
#
#   MIX_ENV=test mix run --no-start bench/core/scoreboard_legacy.exs v2.6.0 v2.7.0
#
# The scoreboard's history (gh-pages) starts at #1133, the first commit that
# draws today's pinned screens (priv/scoreboard/screens.refs); no release
# does. This puts a number on the releases anyway, without claiming they are
# comparable: it feeds today's exact cells for every scenario frame into each
# release's own terminal backend (`Backends.render_to_terminal/2`, v2.4.0 on),
# replays what that backend wrote through today's terminal emulator, and
# reports the bytes next to how many cells came out different from today's
# screen. A release that drops styles sends fewer bytes for a different
# screen; the cell counts say how different.
#
# Each tag is built in its own scratch worktree (../raxol-scoreboard-legacy-
# <tag>, kept for re-runs; remove with `git worktree remove`), with whatever
# toolchain `mix` resolves to there: a version manager that reads the tag's
# pin (mise, asdf) builds v2.4.0 and v2.5.0 on the OTP 26 their dependencies
# need. Frame bytes do not depend on the toolchain. Prints a markdown table.

defmodule ScoreboardLegacy do
  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Rendering.{Backends, Pipeline}
  alias Raxol.Playground.Demos.{FlexLayoutDemo, TableDemo}
  alias Raxol.Terminal.{Emulator, ScreenBuffer}
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Layout.Preparer

  @size %{width: 120, height: 40}
  @scenarios [
    {"table", TableDemo, ~w(j j j j j s j j k b)},
    {"flex", FlexLayoutDemo, []}
  ]

  # Runs inside the tag's checkout: encodes the cells it is given with that
  # release's backend and captures what it writes. Only APIs v2.4.0 has.
  @encoder ~S"""
  Logger.configure(level: :error)
  [cells_path, out_path] = System.argv()
  cells = cells_path |> File.read!() |> :erlang.binary_to_term()

  encoded =
    for {name, frames} <- cells, into: %{} do
      {:ok, device} = StringIO.open("")
      leader = Process.group_leader()
      Process.group_leader(self(), device)
      state = %{width: 120, height: 40, buffer: nil, sync_output: false, force_repaint: false}

      {payloads, _state} =
        Enum.map_reduce(frames, state, fn frame_cells, state ->
          {:ok, state} = Raxol.Core.Runtime.Rendering.Backends.render_to_terminal(frame_cells, state)
          {StringIO.flush(device), state}
        end)

      Process.group_leader(self(), leader)
      {name, payloads}
    end

  File.write!(out_path, :erlang.term_to_binary(encoded))
  """

  def main(tags) do
    today = today()
    dir = Path.join(System.tmp_dir!(), "scoreboard-legacy")
    File.mkdir_p!(dir)
    cells_path = Path.join(dir, "cells.etf")

    File.write!(
      cells_path,
      :erlang.term_to_binary(Map.new(today, fn {n, s} -> {n, s.cells} end))
    )

    rows =
      for tag <- tags do
        payloads = encode_at(tag, cells_path, Path.join(dir, "#{tag}.etf"))
        {tag, compare(payloads, today)}
      end

    print([
      {"today",
       compare(Map.new(today, fn {n, s} -> {n, s.payloads} end), today)}
      | rows
    ])
  end

  # Today's cells and screens per scenario frame, through the same stages as
  # Raxol.Scoreboard; the payloads must equal its frames/2 exactly, or these
  # are not the cells the scoreboard measures.
  defp today do
    for {name, app, keys} <- @scenarios, into: %{} do
      cells = cells(app, keys)
      expected = Raxol.Scoreboard.frames(app, keys)

      {payloads, _} =
        Enum.map_reduce(cells, nil, fn frame_cells, prev ->
          {buffer, payload} =
            Backends.terminal_frame(frame_cells, %{
              width: @size.width,
              height: @size.height,
              buffer: prev,
              force_repaint: false
            })

          {payload, buffer}
        end)

      payloads == Enum.map(expected, &elem(&1, 0)) ||
        raise "#{name}: cells do not reproduce Raxol.Scoreboard.frames/2; update this script's stages"

      {name,
       %{
         cells: cells,
         payloads: payloads,
         screens: Enum.map(expected, &elem(&1, 1))
       }}
    end
  end

  defp cells(app, keys) do
    first = unwrap(app.init(%{}))

    models =
      [first | Enum.scan(keys, first, &unwrap(app.update(key(&1), &2)))]

    {cells, _prepared} =
      Enum.map_reduce(models, nil, fn model, prepared ->
        view = app.view(model)
        prepared = Preparer.prepare_incremental(view, prepared)
        positioned = LayoutEngine.apply_layout(view, @size, prepared)

        cells =
          positioned
          |> Raxol.UI.Renderer.render_to_cells(Pipeline.theme(nil))
          |> Pipeline.apply_border_beam(positioned)

        {cells, prepared}
      end)

    cells
  end

  defp key(char), do: %Event{type: :key, data: %{key: :char, char: char}}
  defp unwrap({model, _commands}), do: model
  defp unwrap(model), do: model

  defp encode_at(tag, cells_path, out_path) do
    work = Path.expand("../raxol-scoreboard-legacy-#{tag}", File.cwd!())

    unless File.dir?(work) do
      git!(["worktree", "add", "--quiet", "--detach", work, tag])
    end

    git!(["-C", work, "reset", "--quiet", "--hard"])
    git!(["-C", work, "checkout", "--quiet", "--detach", tag])

    script = Path.join(work, "scoreboard_legacy_encoder.exs")
    File.write!(script, @encoder)
    env = [{"MIX_ENV", "test"}, {"PATH", Enum.join(unpinned_path(), ":")}]

    try do
      mix!(work, env, ["deps.get"])
      mix!(work, env, ["compile"])
      mix!(work, env, ["run", "--no-start", script, cells_path, out_path])
    after
      File.rm(script)
      git!(["-C", work, "reset", "--quiet", "--hard"])
    end

    out_path |> File.read!() |> :erlang.binary_to_term()
  end

  defp mix!(dir, env, args) do
    {"PATH", path} = List.keyfind(env, "PATH", 0)

    mix =
      path
      |> String.split(":")
      |> Enum.map(&Path.join(&1, "mix"))
      |> Enum.find(&File.regular?/1) || raise "mix is not on PATH"

    # Through sh with stdin from /dev/null: an install prompt (Hex, rebar)
    # fails at once instead of waiting forever on System.cmd's open pipe.
    case System.cmd("sh", ["-c", ~s(exec "$0" "$@" < /dev/null), mix | args],
           cd: dir,
           env: env,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, status} ->
        raise "mix #{Enum.join(args, " ")} in #{dir} exited #{status}:\n#{out}"
    end
  end

  # Version managers put the resolved Elixir and OTP directories on PATH for
  # this process; drop them so `mix` resolves again, in the tag's directory.
  defp unpinned_path do
    pinned = [
      Path.expand("../..", :code.lib_dir(:elixir)),
      to_string(:code.root_dir())
    ]

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(fn dir ->
      Enum.any?(pinned, &String.starts_with?(dir, &1))
    end)
  end

  defp git!(args) do
    {_, 0} = System.cmd("git", args, stderr_to_stdout: true)
  end

  defp compare(payloads, today) do
    for {name, _app, _keys} <- @scenarios, payloads[name], into: %{} do
      frames = payloads[name]
      bytes = Enum.map(frames, &byte_size/1)
      keys = length(bytes) - 1

      diffs =
        frames
        |> Enum.zip(today[name].screens)
        |> Enum.map_reduce(Emulator.new(@size.width, @size.height), fn {payload,
                                                                        want},
                                                                       em ->
          {em, _} = Emulator.process_input(em, payload)
          {differing(want, Emulator.get_screen_buffer(em)), em}
        end)
        |> elem(0)

      {name,
       %{
         keyframe: hd(bytes),
         keystroke: if(keys > 0, do: Enum.sum(tl(bytes)) / keys),
         frames: length(diffs),
         frames_differing: Enum.count(diffs, &(&1 > 0)),
         max_cells: Enum.max(diffs)
       }}
    end
  end

  defp differing(want, got) do
    cells =
      for y <- 0..(want.height - 1)//1, x <- 0..(want.width - 1)//1, do: {x, y}

    Enum.count(cells, fn {x, y} ->
      a = ScreenBuffer.get_cell_at(want, x, y)
      b = ScreenBuffer.get_cell_at(got, x, y)
      a.char != b.char or a.style != b.style
    end)
  end

  defp print(rows) do
    IO.puts(
      "| Release | Table first frame | Table per keystroke | Flex first frame | Cells drawn differently from today |"
    )

    IO.puts("| --- | ---: | ---: | ---: | --- |")

    for {tag, r} <- rows do
      t = r["table"]
      f = r["flex"]

      IO.puts(
        "| #{tag} | #{t.keyframe} B | #{:erlang.float_to_binary(t.keystroke, decimals: 1)} B | #{f.keyframe} B | " <>
          "table: #{diff_text(t)}; flex: #{diff_text(f)} |"
      )
    end
  end

  defp diff_text(%{frames_differing: 0}), do: "none"

  defp diff_text(r),
    do:
      "#{r.frames_differing} of #{r.frames} frames, up to #{r.max_cells} cells"
end

ScoreboardLegacy.main(System.argv())
