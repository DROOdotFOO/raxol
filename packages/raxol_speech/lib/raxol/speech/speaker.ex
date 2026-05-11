defmodule Raxol.Speech.Speaker do
  @moduledoc """
  Speaks accessibility announcements aloud via a TTS backend.

  Subscribes to `Raxol.Core.Accessibility` announcements and forwards
  them to the configured TTS backend. Respects the `:silence_announcements`
  and `:screen_reader` accessibility preferences.

  High-priority announcements interrupt current speech.
  """

  use Raxol.Core.Behaviours.BaseManager

  @compile {:no_warn_undefined, [Raxol.Core.Accessibility]}

  defstruct [
    :tts_backend,
    :subscription_ref
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Speak text directly, bypassing the announcement system."
  @spec speak(String.t()) :: :ok | {:error, term()}
  def speak(text) do
    GenServer.call(__MODULE__, {:speak, text})
  end

  @doc "Stop current speech."
  @spec stop_speaking() :: :ok
  def stop_speaking do
    GenServer.call(__MODULE__, :stop)
  end

  # -- BaseManager --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    tts_backend = Keyword.get(opts, :tts_backend, Raxol.Speech.TTS.OsSay)
    ref = make_ref()

    # Subscribe to accessibility announcements if available
    if Code.ensure_loaded?(Raxol.Core.Accessibility) do
      try do
        Raxol.Core.Accessibility.subscribe_to_announcements(ref)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, %__MODULE__{tts_backend: tts_backend, subscription_ref: ref}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:speak, text}, _from, state) do
    result = state.tts_backend.speak(text)
    {:reply, result, state}
  end

  def handle_manager_call(:stop, _from, state) do
    state.tts_backend.stop()
    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:announcement_added, _ref, message}, state) when is_binary(message) do
    if should_speak?() do
      state.tts_backend.speak(message)
    end

    {:noreply, state}
  end

  def handle_manager_info({:announcement_added, _ref, %{message: message, priority: :high}}, state) do
    if should_speak?() do
      state.tts_backend.stop()
      state.tts_backend.speak(message)
    end

    {:noreply, state}
  end

  def handle_manager_info({:announcement_added, _ref, %{message: message}}, state) do
    if should_speak?() do
      state.tts_backend.speak(message)
    end

    {:noreply, state}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  # -- Private --

  defp should_speak? do
    if Code.ensure_loaded?(Raxol.Core.Accessibility) do
      try do
        prefs = Raxol.Core.Accessibility.get_preferences()
        prefs[:screen_reader] != false and prefs[:silence_announcements] != true
      catch
        :exit, _ -> true
      end
    else
      true
    end
  end
end
