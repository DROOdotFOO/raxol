defmodule Raxol.Symphony.SshPathTest do
  # Blanks PATH, which is VM-global: async modules running alongside would
  # lose `System.find_executable/1`. Kept out of the async SshTest for that.
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Ssh
  alias Raxol.Symphony.Worker.HostSpec

  test "exec returns {:error, :ssh_not_allowed} when the executable can't be resolved" do
    # A blank PATH makes the default resolver fail; the injected exec_fn
    # must never be reached.
    original = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      assert Ssh.exec(%HostSpec{host: "build-1"}, "noop",
               exec_fn: fn _, _, _ -> flunk("should not run") end
             ) == {:error, :ssh_not_allowed}
    after
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end
  end
end
