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

  Optional `:device` selects an IO device other than `:stdio`.
  """
  @spec terminal(keyword()) :: callback()
  def terminal(opts \\ []) do
    device = Keyword.get(opts, :device, :stdio)

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

      answer = IO.gets(device, prompt)
      classify(answer)
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
