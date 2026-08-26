defmodule Raxol.Agent.ClientProtocol.LoginTest do
  @moduledoc """
  `raxol login` is the command an ACP client relaunches us with for Terminal
  Auth, so its contract is the exit code and what it does with a typed key --
  a client reads the former and a user pays for the latter.

  Prompt and print are injected, so nothing here reads a terminal.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Login
  alias Raxol.Agent.ClientProtocol.StdioAgent

  defp io(lines, read \\ fn _ -> "sk-test" end) do
    [print_fn: fn msg -> send(self(), {:printed, msg}) end, read_fn: read] ++
      lines
  end

  defp captured do
    receive do
      {:printed, msg} -> msg
    after
      0 -> nil
    end
  end

  defp all_captured(acc \\ []) do
    receive do
      {:printed, msg} -> all_captured([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "--help exits 0 and names the command" do
    assert 0 = Login.run(["--help"], io([]))
    assert captured() =~ "raxol login"
  end

  test "an unknown option is a usage error, not a silent success" do
    assert 64 = Login.run(["--nope"], io([]))
  end

  test "an empty key is refused rather than stored" do
    assert 1 = Login.run(["anthropic"], io([], fn _ -> "" end))
    assert captured() =~ "no key entered"
  end

  describe "a provider with a browser sign-in" do
    # Approving in a browser beats minting a key by hand, so it is what
    # `raxol login openrouter` does without being asked.
    test "signs in through the browser by default, never prompting for a key" do
      flow = fn provider, _opts ->
        send(self(), {:flow_ran, provider})
        {:ok, %{provider: provider, validation: :valid}}
      end

      read = fn _ -> flunk("prompted for a key when a browser flow exists") end

      assert 0 = Login.run(["openrouter"], io([flow_fn: flow], read))
      assert_received {:flow_ran, :openrouter}
      assert all_captured() =~ "Connected openrouter"
    end

    # A remote box has no browser the loopback redirect can reach, so the
    # typed-key path has to stay reachable.
    test "--paste bypasses the browser and prompts instead" do
      flow = fn _provider, _opts ->
        flunk("opened a browser despite --paste")
      end

      assert 1 =
               Login.run(
                 ["openrouter", "--paste"],
                 io([flow_fn: flow], fn _ -> "" end)
               )

      assert captured() =~ "no key entered"
    end

    test "reports a failed sign-in and points at the fallback" do
      flow = fn _provider, _opts -> {:error, :timeout} end

      assert 1 = Login.run(["openrouter"], io(flow_fn: flow))

      output = all_captured()
      assert output =~ "timed out"
      assert output =~ "--paste"
    end

    # The flow's own browser launch is not fatal here the way it is over ACP:
    # a terminal can print the URL, and the loopback port is still bound.
    test "keeps waiting when the browser will not open, printing the URL" do
      flow = fn provider, opts ->
        # The seam returns :ok even though the launch failed, so the flow does
        # not abandon a port the user can still redeem by hand.
        assert :ok =
                 Keyword.fetch!(opts, :browser_fn).("https://openrouter.ai/auth?x=1")

        {:ok, %{provider: provider, validation: :valid}}
      end

      no_browser = fn _url -> {:error, {:no_browser_opener, "xdg-open"}} end

      assert 0 =
               Login.run(["openrouter"], io(flow_fn: flow, open_fn: no_browser))

      assert all_captured() =~ "https://openrouter.ai/auth?x=1"
    end

    test "says so when the browser did open, and does not print a URL to paste" do
      flow = fn provider, opts ->
        :ok =
          Keyword.fetch!(opts, :browser_fn).("https://openrouter.ai/auth?x=1")

        {:ok, %{provider: provider, validation: :valid}}
      end

      opened = fn _url -> :ok end

      assert 0 = Login.run(["openrouter"], io(flow_fn: flow, open_fn: opened))

      output = all_captured()
      assert output =~ "Opened your browser"
      refute output =~ "Open this URL"
    end
  end

  describe "a provider without a browser sign-in" do
    test "prompts for a key rather than claiming a flow it lacks" do
      flow = fn _provider, _opts ->
        flunk("ran a browser flow for anthropic")
      end

      assert 1 = Login.run(["anthropic"], io([flow_fn: flow], fn _ -> "" end))
      assert captured() =~ "no key entered"
    end
  end

  # Resolved before anything is asked for: there is no reason to prompt for a
  # secret we already know we cannot store.
  test "an unknown provider is a usage error, and lists the known ones" do
    read = fn _ -> flunk("prompted for a key for an unknown provider") end

    assert 64 = Login.run(["nope"], io([], read))

    output = all_captured()
    assert output =~ "unknown provider: nope"
    assert output =~ "openrouter"
  end

  describe "the advertised Terminal Auth method" do
    # The registry's validator infers `terminal` from this _meta key and
    # defaults anything untyped to `agent`. The marker is what keeps the claim
    # honest, so it is asserted rather than assumed.
    test "carries the args a client relaunches us with" do
      method = terminal_method()

      assert method.id == "terminal"
      assert %{"terminal-auth" => %{"args" => ["login"]}} = method._meta
    end

    # If these drift, a client runs a subcommand that does not exist.
    test "names a subcommand the CLI actually dispatches" do
      %{"terminal-auth" => %{"args" => [subcommand]}} = terminal_method()._meta

      assert subcommand == "login"
    end
  end

  defp terminal_method do
    Enum.find(
      StdioAgent.auth_methods(),
      &match?(%{"terminal-auth" => _}, &1._meta)
    )
  end
end
