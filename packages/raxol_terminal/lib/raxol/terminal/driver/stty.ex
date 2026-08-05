defmodule Raxol.Terminal.Driver.Stty do
  @moduledoc false

  # stty operations against the controlling terminal, ALL in the argv
  # form `stty -f|-F DEVICE ...` via `System.cmd/3` -- never a
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
  # DEVICE is resolved (see `tty_device/0`), never the literal
  # `/dev/tty`. That distinction is the difference between this module
  # working and silently doing nothing: the BEAM puts every port child
  # in a FRESH SESSION, so a `System.cmd`-spawned `stty` has no
  # controlling terminal of its own and `/dev/tty` fails ENXIO
  # ("Device not configured") for it -- even when the BEAM itself is
  # sitting on a perfectly good pty. Targeting the resolved device path
  # sidesteps the child's missing ctty entirely.
  #
  # `command_args/1` is the single constructor for every operation's
  # argv, public so the invocation form itself is pinned by test
  # (stty_test.exs, "command construction" describe).

  @raw_flags ~w(raw -echo -icanon -isig)

  # Used only when the controlling terminal cannot be resolved. It is
  # the honest target rather than a working one: if we could not name
  # the device, the command was going to fail anyway, and failing
  # against `/dev/tty` keeps the old behaviour instead of inventing a
  # path that might belong to some other terminal.
  @fallback_device "/dev/tty"

  @doc """
  The argv for each stty operation -- always `[device_flag,
  tty_device() | operation_args]`. Public: the invocation form (device
  flag, never a shell redirect) is itself a pinned regression surface.
  """
  @spec command_args(:raw | :save | :sane | :size | :flags) :: [String.t()]
  def command_args(:raw), do: [file_flag(), tty_device() | @raw_flags]
  def command_args(:save), do: [file_flag(), tty_device(), "-g"]
  def command_args(:sane), do: [file_flag(), tty_device(), "sane"]
  def command_args(:size), do: [file_flag(), tty_device(), "size"]
  def command_args(:flags), do: [file_flag(), tty_device(), "-a"]

  @doc """
  The controlling terminal's device path (`/dev/ttys003`,
  `/dev/pts/3`), or `/dev/tty` when it cannot be resolved.

  Asked of `ps` rather than read from fd 0: `/proc/self/fd/0` is a
  symlink only on Linux (macOS exposes a character device that cannot
  be `readlink`ed), and fd 0 answers "what is stdin" -- which is a pipe
  under any redirect -- where the termios calls here want "what is my
  controlling terminal". `ps -o tty=` answers the second question on
  both platforms.

  Resolved once and cached: fd 0's terminal cannot change for the life
  of the VM, and the guard path (`isig_off?/0`, potentially once per
  input chunk) must not fork `ps` every time.

  `config :raxol_terminal, :stty_device` overrides the resolution. That
  seam exists because these commands really do mutate a real terminal
  now: a test that exercises `restore/1` with a saved-settings value
  would otherwise apply a FOREIGN termios dump to whatever terminal is
  running the suite. Point it at a non-tty to keep a test honest about
  the argv it builds without letting it reach for the developer's
  session. Deliberately read per call, not cached, so it can be set and
  unset around a single test.
  """
  @spec tty_device :: String.t()
  def tty_device do
    case Application.get_env(:raxol_terminal, :stty_device) do
      device when is_binary(device) -> device
      _unset -> resolved_device()
    end
  end

  defp resolved_device do
    case :persistent_term.get({__MODULE__, :tty_device}, :undefined) do
      :undefined ->
        device = resolve_tty_device()
        :persistent_term.put({__MODULE__, :tty_device}, device)
        device

      device ->
        device
    end
  end

  defp resolve_tty_device do
    case System.cmd("ps", ["-o", "tty=", "-p", to_string(:os.getpid())], stderr_to_stdout: true) do
      {out, 0} -> normalize_device(String.trim(out))
      _failed -> @fallback_device
    end
  rescue
    _error -> @fallback_device
  end

  # `ps` reports the bare terminal name (`ttys003`, `pts/3`) and marks
  # "no controlling terminal" as `?`/`??` depending on platform.
  defp normalize_device(name) when name in ["", "?", "??"], do: @fallback_device
  defp normalize_device("/dev/" <> _rest = path), do: path
  defp normalize_device(name), do: "/dev/" <> name

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
  Whether ISIG is currently OFF on the controlling terminal -- read
  from the LIVE flags (`stty -f DEVICE -a`), the referent for "will ^C
  arrive as byte 0x03 or become a SIGINT". `false` when the flags
  cannot be read at all
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
       targets the resolved device (see `tty_device/0`) directly, the
       terminal the old shell redirect (`< /dev/tty`) was reaching for.
  """
  @spec restore(String.t() | nil) :: :ok
  def restore(saved) when is_binary(saved) and byte_size(saved) > 0 do
    if valid_saved_stty?(saved) do
      _ = System.cmd("stty", [file_flag(), tty_device(), saved], stderr_to_stdout: true)
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

  @doc """
  Reset TTY to sane defaults.

  This is the teardown fallback, so a silent no-op here is the worst
  failure the module has: it strands a real terminal in raw mode with
  no echo. It therefore runs through the same resolved-device argv form
  as everything else -- the `sh -c "stty sane < /dev/tty"` it used to
  run was exactly the shell redirect the moduledoc forbids, and it
  failed for exactly the documented reason.
  """
  @spec sane! :: :ok
  def sane! do
    _ = run(:sane)
    :ok
  end

  @doc "Query terminal size via `stty size`. Returns `{:ok, cols, rows}` or `:error`."
  @spec size :: {:ok, pos_integer(), pos_integer()} | :error
  def size do
    str =
      case run(:size) do
        {out, 0} -> String.trim(out)
        _failed -> ""
      end

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
