defmodule Raxol.Terminal.Buffer.WriterLoggingTest do
  # `write_char/5` runs once per cell of every frame the runtime draws
  # (`Raxol.Core.Runtime.Rendering.Backends` writes the frame cell by cell),
  # so any log line in it is one line per cell per frame.
  #
  # async: false because the Logger level is node-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Terminal.ScreenBuffer

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "writing a frame of cells logs nothing, even at :debug" do
    buffer = ScreenBuffer.new(20, 5)

    {frame, log} =
      with_log([level: :debug], fn ->
        for y <- 0..4, x <- 0..19, reduce: buffer do
          acc -> ScreenBuffer.write_char(acc, x, y, "x")
        end
      end)

    assert ScreenBuffer.get_char(frame, 19, 4) == "x"
    assert log == ""
  end
end
