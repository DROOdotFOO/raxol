defmodule Raxol.Test.InlineDriverMockStty do
  @moduledoc """
  Recording stub for `Raxol.Terminal.InlineDriver`'s injectable `:stty`
  option (unit T2d). The real `Raxol.Terminal.Driver.Stty` shells out to
  `/dev/tty`; this stub never touches any OS tty at all, so Tier A tests can
  force `stty_enabled?: true` (to assert *that* the injected module gets
  called, and in what order relative to byte writes) without any risk to
  the tty actually running the test suite.

  Functions match `Raxol.Terminal.Driver.Stty`'s public arity exactly, so
  this is a drop-in `:stty` constructor option. Calls are recorded to a
  named `Agent` (started/stopped per test) so tests can assert order.
  """

  use Agent

  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    Agent.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @doc "Recorded calls, oldest first."
  @spec calls() :: [tuple()]
  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

  @spec save() :: String.t()
  def save do
    record({:save})
    "mock-original-settings"
  end

  @spec raw!() :: :ok
  def raw! do
    record({:raw!})
    :ok
  end

  @spec restore(String.t() | nil) :: :ok
  def restore(saved) do
    record({:restore, saved})
    :ok
  end

  @spec size() :: {:ok, pos_integer(), pos_integer()}
  def size, do: {:ok, 80, 24}

  defp record(call), do: Agent.update(__MODULE__, &[call | &1])
end
