defmodule Raxol.Terminal.Driver.Stty do
  @moduledoc false

  # Thin wrapper around `:os.cmd/1` (and, for `restore/1`, `System.cmd/3`)
  # for stty operations on /dev/tty.
  #
  # `save/0`, `raw!/0`, `sane!/0`, and `size/0` take no user-controlled
  # input at all -- their commands are hardcoded charlists, so `:os.cmd/1`
  # (which runs them through `/bin/sh -c`) is safe as-is. Centralizes the
  # Credo.Check.Warning.UnsafeExec suppression for those to one place.
  #
  # `restore/1`'s argument is different in kind: it is whatever `save/0`
  # last captured, round-tripped through `InlineDriver`'s GenServer state
  # (and, in tests, an arbitrary injected `:stty` module) -- so it is
  # untrusted by the time it reaches here and must never be spliced into a
  # shell command line. See `restore/1` below.

  @doc "Save current TTY settings (stty -g). Returns empty string on failure."
  @spec save :: String.t()
  def save do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    :os.cmd(~c"stty -g < /dev/tty 2>/dev/null")
    |> List.to_string()
    |> String.trim()
  end

  @doc "Enter raw mode: no echo, no line buffering, no signals."
  @spec raw! :: :ok
  def raw! do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    _ = :os.cmd(~c"stty raw -echo -icanon -isig < /dev/tty 2>/dev/null")
    :ok
  end

  # Conservative allowlist for a `save/0` dump: `stty -g` output (GNU and
  # BSD/macOS alike) is colon-separated decimal/hex fields -- word
  # characters, `:`, `,`, `=`, `.`, `-`, and whitespace, nothing else.
  # Deliberately EXCLUDES shell metacharacters (`; & | < > $` and
  # backticks) and `/` (never appears in real `-g` output either), so a
  # corrupted or adversarial value can never be mistaken for a plausible
  # settings dump and falls straight through to `sane!/0` instead.
  @valid_saved_stty ~r/\A[\w:,=.\-\s]+\z/

  @doc """
  Restore previously saved TTY settings, or fall back to `stty sane`.

  Two independent layers, since `saved` is untrusted input (see the
  moduledoc):

    1. `saved` must match `valid_saved_stty?/1`'s allowlist or this falls
       straight through to `sane!/0` without ever touching a command line.
    2. Even a validated value is applied via `System.cmd/3` (argv, no
       shell) rather than `:os.cmd/1` -- `saved` is passed to `stty` as one
       literal argument, so there is no shell in the loop left to
       reinterpret it at all. `-F`/`-f DEVICE` (GNU/BSD respectively)
       targets `/dev/tty` directly, the same device the old shell
       redirect (`< /dev/tty`) pointed at.
  """
  @spec restore(String.t() | nil) :: :ok
  def restore(saved) when is_binary(saved) and byte_size(saved) > 0 do
    if valid_saved_stty?(saved) do
      _ = System.cmd("stty", [file_flag(), "/dev/tty", saved], stderr_to_stdout: true)
      :ok
    else
      sane!()
    end
  end

  def restore(_), do: sane!()

  @spec valid_saved_stty?(String.t()) :: boolean()
  defp valid_saved_stty?(saved), do: Regex.match?(@valid_saved_stty, saved)

  # GNU coreutils' `stty` takes `-F DEVICE`; BSD/macOS `stty` takes
  # `-f DEVICE`. Both mean "operate on DEVICE directly" -- required here
  # since a `System.cmd`-spawned port's inherited stdin is a pipe, not the
  # real controlling terminal.
  defp file_flag do
    case :os.type() do
      {:unix, :linux} -> "-F"
      _ -> "-f"
    end
  end

  @doc "Reset TTY to sane defaults."
  @spec sane! :: :ok
  def sane! do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    _ = :os.cmd(~c"stty sane < /dev/tty 2>/dev/null")
    :ok
  end

  @doc "Query terminal size via `stty size`. Returns `{:ok, cols, rows}` or `:error`."
  @spec size :: {:ok, pos_integer(), pos_integer()} | :error
  def size do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    result = :os.cmd(~c"stty size < /dev/tty 2>/dev/null")
    str = result |> List.to_string() |> String.trim()

    case String.split(str) do
      [rows_s, cols_s] ->
        rows = String.to_integer(rows_s)
        cols = String.to_integer(cols_s)
        if rows > 0 and cols > 0, do: {:ok, cols, rows}, else: :error

      _ ->
        :error
    end
  end
end
