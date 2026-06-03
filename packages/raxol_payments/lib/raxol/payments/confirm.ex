defmodule Raxol.Payments.Confirm do
  @moduledoc """
  Built-in confirmation callbacks for `Raxol.Payments.Req.AutoPay`'s
  `:on_confirm` option.

  Agents handling payments above `policy.require_confirmation_above`
  need a way to escalate to a human. This module provides ready-made
  callbacks for the common surfaces. All have the shape
  `(amount, domain) -> :approve | :deny` so they slot straight into
  `AutoPay.attach/2`.

  ## Terminal prompt

      AutoPay.attach(req,
        wallet: MyWallet,
        policy: policy,
        ledger: ledger,
        on_confirm: Raxol.Payments.Confirm.terminal()
      )

  When the gate fires, the agent process blocks on `IO.gets/1` until you
  type `y` or `n`. Only use this when there is a real interactive TTY on
  the agent's process group leader.

  ## Auto-approve / auto-deny (testing only)

      Raxol.Payments.Confirm.always(:approve)
      Raxol.Payments.Confirm.always(:deny)

  Useful in tests and rehearsals where you want to exercise the callback
  path without a human in the loop.
  """

  @type decision :: :approve | :deny
  @type callback :: (Decimal.t(), String.t() -> decision())

  @doc """
  Build a callback that prompts on stdin and reads the answer with `IO.gets/1`.

  Treats anything starting with `y` (case-insensitive) as `:approve`,
  everything else (including an empty answer or EOF) as `:deny`.

  ## Options

  - `:device` -- IO device, default `:stdio`.
  - `:timeout_ms` -- max time to wait for an answer, default `60_000`.
    On timeout the callback denies. Pass `:infinity` to wait forever
    (the old behavior); only safe when you know there's a real human
    on a real TTY.
  """
  @spec terminal(keyword()) :: callback()
  def terminal(opts \\ []) do
    device = Keyword.get(opts, :device, :stdio)
    timeout = Keyword.get(opts, :timeout_ms, 60_000)

    fn amount, domain ->
      prompt =
        IO.ANSI.format([
          :yellow,
          "\n[payment confirmation] ",
          :reset,
          "approve ",
          :bright,
          Decimal.to_string(amount),
          :reset,
          " to ",
          :bright,
          domain,
          :reset,
          "? [y/N] "
        ])

      read_with_timeout(device, prompt, timeout)
    end
  end

  defp read_with_timeout(device, prompt, :infinity) do
    IO.gets(device, prompt) |> classify()
  end

  defp read_with_timeout(device, prompt, timeout_ms)
       when is_integer(timeout_ms) do
    task = Task.async(fn -> IO.gets(device, prompt) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> classify(answer)
      _ -> :deny
    end
  end

  @doc """
  Always returns the same decision. For tests and rehearsals.
  """
  @spec always(decision()) :: callback()
  def always(decision) when decision in [:approve, :deny] do
    fn _amount, _domain -> decision end
  end

  defp classify(answer) when is_binary(answer) do
    case answer |> String.trim() |> String.downcase() do
      "y" <> _ -> :approve
      _ -> :deny
    end
  end

  defp classify(_), do: :deny
end
