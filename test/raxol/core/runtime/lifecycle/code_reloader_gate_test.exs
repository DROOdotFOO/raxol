defmodule Raxol.Core.Runtime.Lifecycle.CodeReloaderGateTest do
  @moduledoc """
  Whether a Lifecycle started in `:dev` gets a `Raxol.Dev.CodeReloader`.
  """
  # async: false: the Mix environment and the reloader's name are global.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Core.Runtime.Lifecycle
  alias Raxol.Dev.CodeReloader

  defmodule App do
    @moduledoc false
    def init(_), do: {:ok, %{}}
    def update(_msg, model), do: {model, []}
    def view(_model), do: %{type: :text, content: "ok"}
  end

  setup do
    env = Mix.env()
    Mix.env(:dev)

    on_exit(fn ->
      Mix.env(env)
      Application.delete_env(:raxol, :code_reloader)
    end)
  end

  test "it gets one by default" do
    lifecycle = start_lifecycle()

    assert is_pid(Process.whereis(CodeReloader))
    stop(lifecycle)
  end

  test "it gets none when config :raxol, :code_reloader is false" do
    Application.put_env(:raxol, :code_reloader, false)
    lifecycle = start_lifecycle()

    assert Process.whereis(CodeReloader) == nil
    stop(lifecycle)
  end

  defp start_lifecycle do
    name = :"reloader_gate_#{System.unique_integer([:positive])}"
    {:ok, pid} = Lifecycle.start_link(App, environment: :agent, name: name)
    Process.unlink(pid)
    pid
  end

  # The reloader is stopped in the Lifecycle's terminate, before it is down.
  defp stop(lifecycle) do
    ref = Process.monitor(lifecycle)
    Lifecycle.stop(lifecycle)
    assert_receive {:DOWN, ^ref, :process, ^lifecycle, _reason}, 5_000
  end
end
