defmodule Raxol.Terminal.PtyHarness do
  @moduledoc """
  Drives the real `InlineDriver` inside a real pty and reports what it decoded.

  The mechanism shared by every test that cannot be had without a genuine
  terminal: the protocol canary and the `-isig` contract both need an actual
  tty, a real multiplexer to type into, and the driver's own in-VM account of
  what it established. What they DIFFER on is the claim, so this module stops
  at the evidence: it returns the stage reached, the tokens decoded, and the
  app's diagnostics, and leaves every interpretation to the caller. Stage prose
  in particular belongs to the test -- `:no_output` means "the reader is wedged"
  to one of them and "SIGINT killed the app" to the other, and a shared
  explanation could only be vague enough to fit both.

  ## The app under the pty

  `test/fixtures/input_canary_app.exs`, booted through `mix run` inside the
  multiplexer. It arms the driver, writes `<out>.ready` with its diagnostics,
  collects `CANARY_N` key events, writes one token per line to `<out>`, and
  halts. Everything here is bookkeeping around that file pair.

  ## Keys

  `{:literal, "a"}` sends bytes verbatim (tmux `-l`). `{:named, "C-c"}` sends a
  tmux key NAME, which must NOT go through `-l` or tmux types the three
  characters `C`, `-`, `c` instead of the control byte.

  ## Retries

  A cold pty boot can drop the first keystroke if it lands before the reader
  has armed its select loop -- a timing flake, not a real failure. `run/3`
  retries the whole drive, so a genuine break fails every attempt while a race
  succeeds on a later one.
  """

  @app Path.expand("../fixtures/input_canary_app.exs", __DIR__)
  @pkg_dir Path.expand("../..", __DIR__)
  @gap_ms 300
  # Settle after the reader signals ready, before the first keystroke, so its
  # select loop is armed.
  @settle_ms 250
  @max_attempts 3
  @ready_suffix ".ready"
  @ready_tries 900
  @output_tries 60

  @type key :: {:literal, String.t()} | {:named, String.t()}
  @type stage :: :ok | :empty | :partial | :no_output | :ready_timeout | :send_failed
  @type result :: %{
          tokens: [String.t()],
          stage: stage(),
          diag: String.t(),
          attempts: pos_integer()
        }

  @doc """
  The multiplexer to drive with, or `nil` when neither is installed.

  tmux when present (the same mechanism the Terminal-Bench harness uses to
  drive agents), else `expect` as a portable fallback.
  """
  @spec driver :: :tmux | :expect | nil
  def driver do
    cond do
      System.find_executable("tmux") -> :tmux
      System.find_executable("expect") -> :expect
      true -> nil
    end
  end

  @doc """
  The budget the app is given to boot and signal ready, in ms. Only here so a
  failure report can quote it.
  """
  @spec ready_budget_ms :: pos_integer()
  def ready_budget_ms, do: @ready_tries * 100

  @doc """
  Type `keys` into a real pty and report what the app decoded.

  Retries until the tokens match `expected` or the attempts run out, so
  `expected` is a stopping condition, NOT an assertion -- the caller still has
  to assert on the returned tokens. Passing them in is what lets a flake
  retry while a real failure returns promptly with its evidence intact.
  """
  @spec run(:tmux | :expect, [key()], [String.t()]) :: result()
  def run(driver, keys, expected, attempts_left \\ @max_attempts, attempt \\ 1) do
    result = attempt_drive(driver, keys)

    cond do
      result.tokens == expected -> Map.put(result, :attempts, attempt)
      attempts_left <= 1 -> Map.put(result, :attempts, attempt)
      true -> run(driver, keys, expected, attempts_left - 1, attempt + 1)
    end
  end

  @doc """
  The common failure skeleton: what was expected, what arrived, how far it got,
  and the app's own view from inside the pty. `explanation` is the caller's --
  what the stage means for THAT claim.
  """
  @spec report(result(), :tmux | :expect, [String.t()], String.t()) :: String.t()
  def report(result, driver, expected, explanation) do
    """
    Real-pty input test FAILED on OTP #{System.otp_release()} \
    (driver: #{driver}) after #{result.attempts} attempt(s), \
    at stage: #{result.stage}.
    Expected #{inspect(expected)}, got #{inspect(result.tokens)}.

    #{explanation}

    In-VM diagnostics from the app (#{@ready_suffix} file):
      #{result.diag}
    """
  end

  defp attempt_drive(driver, keys) do
    out = Path.join(System.tmp_dir!(), "raxol_input_canary_#{unique()}")

    try do
      stage = drive(driver, out, keys)
      diag = read_diagnostics(out)

      case {stage, File.read(out)} do
        {:sent, {:ok, body}} ->
          tokens = String.split(body, "\n", trim: true)
          %{tokens: tokens, stage: classify(tokens, keys), diag: diag}

        {:sent, {:error, _}} ->
          %{tokens: [], stage: :no_output, diag: diag}

        {stage, _} ->
          %{tokens: [], stage: stage, diag: diag}
      end
    after
      File.rm(out)
      File.rm(out <> @ready_suffix)
    end
  end

  defp classify([], _keys), do: :empty
  defp classify(tokens, keys) when length(tokens) < length(keys), do: :partial
  defp classify(_tokens, _keys), do: :ok

  # The app's own account of what it established. Absent when it never got far
  # enough to write one, which is itself the answer.
  defp read_diagnostics(out) do
    case File.read(out <> @ready_suffix) do
      {:ok, body} -> String.trim(body)
      {:error, _} -> "(no ready file -- the app never signalled)"
    end
  end

  defp drive(:tmux, out, keys) do
    session = "raxol-input-canary-#{unique()}"

    cmd =
      "cd #{@pkg_dir} && CANARY_OUT=#{out} CANARY_N=#{length(keys)} " <>
        "MIX_ENV=test mix run --no-compile #{@app}"

    try do
      {_, 0} =
        System.cmd(
          "tmux",
          ["new-session", "-d", "-s", session, "-x", "80", "-y", "24", cmd],
          stderr_to_stdout: true
        )

      # Only type once the reader signalled ready, then settle briefly so its
      # select loop is armed.
      case wait_for_ready(out) do
        :ok ->
          Process.sleep(@settle_ms)
          type_all(session, out, keys)

        :timeout ->
          :ready_timeout
      end
    after
      System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    end
  end

  defp drive(:expect, out, keys) do
    # The app `System.halt/0`s right after writing output, so `eof` returns
    # promptly. `--no-compile`: the parent test already compiled, so the nested
    # run must not recompile under lock contention.
    sends =
      keys
      |> Enum.map(&~s|send "#{expect_bytes(&1)}"\nafter #{@gap_ms}|)
      |> Enum.join("\n")

    script = """
    set timeout 120
    spawn env CANARY_OUT=#{out} CANARY_N=#{length(keys)} MIX_ENV=test mix run --no-compile #{@app}
    set t 0
    while {![file exists "#{out}.ready"] && $t < #{@ready_tries}} { after 100; incr t }
    after #{@settle_ms}
    #{sends}
    expect eof
    """

    System.cmd("expect", ["-c", script], cd: @pkg_dir, stderr_to_stdout: true)

    # `expect` does its own waiting inside the script, so reaching here means
    # the keystrokes were written to the pty.
    :sent
  end

  defp type_all(session, out, keys) do
    result =
      Enum.reduce_while(keys, :ok, fn key, _acc ->
        case send_key(session, key) do
          :ok ->
            Process.sleep(@gap_ms)
            {:cont, :ok}

          other ->
            {:halt, other}
        end
      end)

    case result do
      :ok ->
        wait_for_output(out)
        :sent

      other ->
        other
    end
  end

  # A refused keystroke must not read as a decode failure. The exit status was
  # dropped once, which made a dead tmux session and a moved protocol produce
  # the same empty result.
  defp send_key(session, key) do
    args =
      case key do
        {:literal, k} -> ["send-keys", "-t", session, "-l", k]
        {:named, k} -> ["send-keys", "-t", session, k]
      end

    case System.cmd("tmux", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_out, _status} -> :send_failed
    end
  end

  defp expect_bytes({:literal, k}), do: k
  defp expect_bytes({:named, "C-c"}), do: "\\003"

  # Type only once the reader is armed, so we never send before the pty listens.
  defp wait_for_ready(out), do: poll(out <> @ready_suffix, @ready_tries)
  defp wait_for_output(out), do: poll(out, @output_tries)

  defp poll(_path, 0), do: :timeout

  defp poll(path, tries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(100)
      poll(path, tries - 1)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
