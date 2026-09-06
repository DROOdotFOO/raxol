defmodule RaxolCli.MixProject do
  use Mix.Project

  @version "0.2.6"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_cli,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      description: description(),
      package: package(),
      name: "RaxolCli",
      source_url: @source_url
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    # Self-run the CLI outside :test only; in :test the modules are a passive
    # dependency and the suite drives the dispatcher directly.
    if Mix.env() != :test do
      Keyword.put(app, :mod, {Raxol.CLI.Application, []})
    else
      app
    end
  end

  # The `raxol` command. Burrito wraps the release into a self-contained
  # executable per target; the `raxol` npm package (npm/) ships those binaries.
  # Build one target with `BURRITO_TARGET=<name> MIX_ENV=prod mix release`.
  defp releases do
    [
      raxol_cli: [
        include_executables_for: [:unix, :windows],
        steps: [:assemble, &patch_burrito_launcher/1, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

  # Burrito 1.6.0 spawns the BEAM with stdout on a pipe so its launcher can
  # notice a downstream consumer going away (`raxol code | head -5`). That costs
  # the child its terminal, and two separate gates then read as "no terminal":
  # `:io.getopts()` (which vetoed `raxol code` and `raxol playground` outright)
  # and `:prim_tty.isatty(:stdout)` behind
  # `Raxol.Terminal.TerminalUtils.has_terminal_device?/0` (which made the driver
  # skip raw mode and the alternate screen, so the TUI drew but ignored every
  # keystroke). Inheriting a stdout that is already a tty loses nothing: the
  # EPIPE this guards against needs a downstream consumer holding the far end,
  # which is exactly the not-a-tty case.
  #
  # Upstream exposes no option for this, so patch the dependency on the way to
  # wrapping it. `mix deps.get` restores the original and this runs again, which
  # is what makes the fix survive a clean checkout. raxol carries its own
  # defence for the same failure (see `has_terminal_device?/0`); this half fixes
  # the cause rather than tolerating it. Remove once burrito ships the fix.
  @burrito_patches [
    {"    if (builtin.os.tag != .windows) {\n" <>
       "        child = try std.process.spawn(io, .{\n" <>
       "            .argv = final_args,\n" <>
       "            .environ_map = env_map,\n" <>
       "            .stdout = .pipe,\n" <>
       "        });",
     "    const stdout_is_tty = Io.File.stdout().isTty(io) catch false;\n\n" <>
       "    if (builtin.os.tag != .windows and !stdout_is_tty) {\n" <>
       "        child = try std.process.spawn(io, .{\n" <>
       "            .argv = final_args,\n" <>
       "            .environ_map = env_map,\n" <>
       "            .stdout = .pipe,\n" <>
       "        });"},
    # Keyed on the copy thread rather than the OS: with an inherited tty there
    # is no thread to join, and `copy_thread.?` would panic on that path.
    {"    const term = if (builtin.os.tag != .windows)\n",
     "    const term = if (copy_thread != null)\n"}
  ]

  @doc false
  # Public only so the patch can be exercised without a full release build.
  def patch_burrito_launcher(release) do
    path =
      Path.join([
        Mix.Project.deps_path(),
        "burrito",
        "src",
        "erlang_launcher.zig"
      ])

    original = File.read!(path)

    patched =
      Enum.reduce(
        @burrito_patches,
        original,
        &apply_burrito_patch(&1, &2, path)
      )

    if patched != original, do: File.write!(path, patched)

    release
  end

  defp apply_burrito_patch({from, to}, source, path) do
    cond do
      String.contains?(source, to) ->
        source

      String.contains?(source, from) ->
        String.replace(source, from, to, global: false)

      true ->
        Mix.raise(burrito_patch_error(path))
    end
  end

  # Fail the build rather than ship a binary whose TUI cannot be typed into.
  defp burrito_patch_error(path) do
    """
    Could not apply the burrito stdout fix to #{path}.

    Neither the original source nor the patched form was found, so burrito's
    launcher has changed and this patch no longer describes it. Re-derive it
    against the new source before releasing: without it the packaged `raxol
    code` and `raxol playground` refuse to start, and lifting only that veto
    leaves a TUI that renders and ignores the keyboard.
    """
  end

  # `skip_nifs: true`: each target is built natively (CI builds the arch it runs
  # on), so the termbox NIF from `mix release` assemble already matches the target.
  # Windows carries no NIF to skip or ship: `raxol_terminal`'s mix.exs drops
  # `:elixir_make` entirely on `{:win32, _}` and the driver falls back to the
  # pure-Elixir `IOTerminal`, which is the path the windows-2022 CI leg already
  # exercises. So the target is a native build like the others, minus the C.
  defp burrito_targets do
    [
      linux: [os: :linux, cpu: :x86_64, skip_nifs: true],
      linux_arm: [os: :linux, cpu: :aarch64, skip_nifs: true],
      macos: [os: :darwin, cpu: :aarch64, skip_nifs: true],
      windows: [os: :windows, cpu: :x86_64, skip_nifs: true]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Main raxol for the terminal runtime + the Playground app; raxol_agent for
      # the interactive agent turn. raxol_agent pulls main raxol transitively, but
      # the direct dep documents the CLI's reliance on Raxol.start_link/Playground.
      raxol_dep(:raxol, "~> 2.6", "../.."),
      raxol_dep(:raxol_agent, "~> 2.6", "../raxol_agent"),

      # Packaging + argv access. Runtime (not build-only) here: the CLI reads the
      # wrapped argv via `Burrito.Util.Args` at startup, so the module must ship
      # in the release.
      {:burrito, "~> 1.6"},

      # The HTTP client behind every remote provider. raxol_agent declares it
      # optional, and optional deps do not propagate, so without this line the
      # packaged binary's LLM path works only by accident -- burrito happens to
      # pull req in today, and Backend.HTTP would return :req_not_available the
      # day it stops.
      {:req, "~> 0.5"},

      # The CA trust store, and the reason `req` alone is not enough. castore is
      # an OPTIONAL dep of mint, so it lands in the lock but is never compiled
      # into the release -- the packaged binary then has no trust store and
      # Mint raises "default CA trust store not available" on the FIRST HTTPS
      # connect, i.e. every remote LLM call. Declaring it here is what ships it.
      # Host OS certs are not a substitute: something must still load them
      # (`:public_key.cacerts_load/0`), and a self-contained binary that
      # promises no Erlang install should not depend on the host's cert bundle
      # existing at all.
      {:castore, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ acp_dep()
  end

  # `raxol acp` serves the agent over the Agent Client Protocol, and
  # `Raxol.Agent.ClientProtocol.StdioAgent` is compile-gated on this package's
  # presence -- without it the packaged binary would ship the subcommand but not
  # the surface behind it. raxol_agent declares the same path dep; this one
  # documents what the CLI distributes. Both drop out under HEX_BUILD, since the
  # package is unpublished and must never appear as a Hex requirement.
  defp acp_dep do
    path = "../raxol_agent_client_protocol"

    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      []
    else
      [{:raxol_agent_client_protocol, path: path, override: true}]
    end
  end

  defp raxol_dep(name, version, path) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version}
    else
      {name, version, [path: path, override: true]}
    end
  end

  defp description do
    """
    The `raxol` command: an interactive AI agent and Raxol toolkit in your
    terminal, shipped as a self-contained binary via an npm wrapper.
    """
  end

  defp package do
    [
      name: "raxol_cli",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Raxol Team"]
    ]
  end
end
