defmodule Raxol.Terminal.Driver.Stty do
  @moduledoc false

  # stty operations against /dev/tty, ALL in the argv form
  # `stty -f|-F /dev/tty ...` via `System.cmd/3` -- never a
  # `sh -c "stty ... < /dev/tty"` shell redirect. Two reasons, both
  # learned the hard way (the real-terminal ^C trap):
  #
  #   * the shell-redirect form silently no-ops wherever the /bin/sh
  #     child cannot open a controlling tty (some pty harnesses; any
  #     environment where the BEAM's session lost its ctty) -- the argv
  #     device flag targets the device explicitly and fails LOUDLY into
  #     the `{output, nonzero}` return instead;
  #   * argv means no shell in the loop at all, which is also why
  #     `restore/1`'s untrusted saved value was already using it.
  #
  # `command_args/1` is the single constructor for every operation's
  # argv, public so the invocation form itself is pinned by test
  # (stty_test.exs, "command construction" describe).

  @raw_flags ~w(raw -echo -icanon -isig)

  @doc """
  The argv for each stty operation -- always `[device_flag, "/dev/tty" |
  operation_args]`. Public: the invocation form (device flag, never a
  shell redirect) is itself a pinned regression surface.
  """
  @spec command_args(:raw | :save | :sane | :size | :flags) :: [String.t()]
  def command_args(:raw), do: [file_flag(), "/dev/tty" | @raw_flags]
  def command_args(:save), do: [file_flag(), "/dev/tty", "-g"]
  def command_args(:sane), do: [file_flag(), "/dev/tty", "sane"]
  def command_args(:size), do: [file_flag(), "/dev/tty", "size"]
  def command_args(:flags), do: [file_flag(), "/dev/tty", "-a"]

  # Runs one constructed command. `{output, exit_status}`; never raises
  # (a missing binary or an un-openable /dev/tty degrades to `{"", 1}` --
  # callers treat any nonzero status as "cannot confirm").
  defp run(op) do
    System.cmd("stty", command_args(op), stderr_to_stdout: true)
  rescue
    _error -> {"", 1}
  end

  @doc "Save current TTY settings (stty -g). Returns empty string on failure."
  @spec save :: String.t()
  def save do
    case run(:save) do
      {out, 0} -> String.trim(out)
      _failed -> ""
    end
  end

  @doc "Enter raw mode: no echo, no line buffering, no signals."
  @spec raw! :: :ok
  def raw! do
    _ = run(:raw)
    :ok
  end

  @doc """
  Whether ISIG is currently OFF on /dev/tty -- read from the LIVE flags
  (`stty -f /dev/tty -a`), the referent for "will ^C arrive as byte 0x03
  or become a SIGINT". `false` when the flags cannot be read at all
  (no controlling tty): the honest answer is "cannot confirm", never a
  raise and never an assumed yes.
  """
  @spec isig_off? :: boolean()
  def isig_off? do
    case run(:flags) do
      {out, 0} -> String.contains?(out, "-isig")
      _failed -> false
    end
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
