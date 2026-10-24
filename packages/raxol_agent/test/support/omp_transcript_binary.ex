defmodule Raxol.Agent.OMPTranscriptBinary do
  @moduledoc false
  # A stand-in `omp` for tests: a shell script that runs the generic,
  # content-free transcript player (`gateway_transcript_player.exs`) on a
  # recorded fixture, so a client vets, version-checks and spawns it like the
  # real binary. Rewriting it changes what the NEXT spawn runs.

  @player Path.expand("gateway_transcript_player.exs", __DIR__)

  @doc "Write `dir/omp` playing `fixture` in `mode`; returns its path."
  @spec write(Path.t(), Path.t(), String.t()) :: Path.t()
  def write(dir, fixture, mode) do
    path = Path.join(dir, "omp")
    elixir = System.find_executable("elixir")

    File.write!(path, """
    #!/bin/sh
    exec '#{elixir}' '#{@player}' '#{fixture}' '#{mode}' "$@"
    """)

    File.chmod!(path, 0o755)
    path
  end
end
