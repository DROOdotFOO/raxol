defmodule T0.RingB.Osa do
  @moduledoc """
  Shared osascript plumbing for the two AppleScript-driven drivers
  (iTerm2, Terminal.app). Scripts are written to a unique temp file and
  run via `osascript path.applescript` rather than `-e` — verified
  empirically that a multi-line `-e` string is fragile to quote/escaping
  edge cases, while a file avoids the whole class of problem and lets us
  write natural multi-line `tell` blocks.

  `run/1`'s output is `String.trim_trailing/1`'d only for the trailing
  newline osascript itself appends to stdout — callers must NOT further
  trim per-line whitespace here (that's `T0.RingB.Capture`'s job, and
  doing it twice would silently absorb real terminal padding
  differences between drivers into this "shared" layer instead of
  leaving it visible in the driver-specific evidence dump).
  """

  @spec run(String.t()) :: {:ok, String.t()} | {:error, term()}
  def run(script) do
    path = tmp_path()

    try do
      File.write!(path, script)

      case System.cmd("osascript", [path], stderr_to_stdout: false) do
        {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
        {out, code} -> {:error, {:osascript_exit, code, String.trim(out)}}
      end
    rescue
      e -> {:error, {:osascript_raised, Exception.message(e)}}
    after
      File.rm(path)
    end
  end

  @doc "Escapes a value for embedding inside a double-quoted AppleScript string literal."
  @spec escape(String.t()) :: String.t()
  def escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "t0-ringb-#{System.unique_integer([:positive])}.applescript"
    )
  end
end
