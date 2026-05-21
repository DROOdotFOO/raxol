defmodule Raxol.Speech.TTS.Noop do
  @moduledoc """
  Silent TTS backend for testing and CI.

  Records all `speak/1` calls so tests can assert on what was spoken.
  """

  @behaviour Raxol.Speech.TTS.Backend

  use Agent

  require Logger

  @mix_env if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod
  @warn_on_start @mix_env not in [:test, :dev]

  def start_link(_opts \\ []) do
    if @warn_on_start do
      Logger.warning(
        "Raxol.Speech.TTS.Noop is running outside test/dev -- speech will be silently discarded. Configure a real backend (OsSay) for production."
      )
    end

    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl Raxol.Speech.TTS.Backend
  def speak(text) when is_binary(text) do
    Agent.update(__MODULE__, &[text | &1])
    :ok
  end

  @impl Raxol.Speech.TTS.Backend
  def stop, do: :ok

  @impl Raxol.Speech.TTS.Backend
  def speaking?, do: false

  @doc "Returns all texts that were spoken, newest first."
  @spec get_spoken() :: [String.t()]
  def get_spoken do
    Agent.get(__MODULE__, & &1)
  end

  @doc "Clears the spoken history."
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
