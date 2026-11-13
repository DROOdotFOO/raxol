defmodule Raxol.Agent.SessionLinkGuardTest do
  @moduledoc """
  `Raxol.Agent.Session` starts its Lifecycle with `start_link` and must unlink
  it at once: left linked, a Lifecycle crash is an exit signal that kills the
  session instead of a `:DOWN` it handles. This guards the source line.
  """
  use ExUnit.Case, async: true

  @session Path.expand("../../../lib/raxol/agent/session.ex", __DIR__)

  test "session.ex unlinks the lifecycle it starts" do
    assert File.read!(@session) =~ "Process.unlink(lifecycle_pid)",
           "#{@session} must contain Process.unlink(lifecycle_pid) " <>
             "to prevent crash propagation through process links"
  end
end
