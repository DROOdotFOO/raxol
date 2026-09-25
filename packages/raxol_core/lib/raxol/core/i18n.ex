defmodule Raxol.Core.I18n do
  @moduledoc """
  Refactored internationalization module using GenServer for state management.

  This module provides the same API as the original I18n module but delegates
  all state management to a supervised GenServer, eliminating Process dictionary usage.

  ## Migration Guide

  1. Add the I18n.I18nServer to your supervision tree:

      children = [
        {Raxol.Core.I18n.I18nServer, name: Raxol.Core.I18n.I18nServer, config: config}
      ]

  2. Replace `Raxol.Core.I18n` with `Raxol.Core.I18n` in your code

  3. All API calls remain the same
  """

  alias Raxol.Core.I18n.I18nServer

  @server Raxol.Core.I18n.I18nServer

  @doc """
  Initialize the i18n framework.

  Now initializes the GenServer state instead of Process dictionary.
  """
  def init(config \\ []) do
    # Normalize config to map - handle both keyword lists and maps
    config_map =
      cond do
        is_map(config) -> config
        is_list(config) and Keyword.keyword?(config) -> Enum.into(config, %{})
        is_list(config) and config == [] -> %{}
        true -> config
      end

    ensure_server_started(config_map)
    I18nServer.init_i18n(@server, config_map)
  end

  @doc """
  Get a translated string for the given key.

  ## Examples

      iex> I18n.t("welcome_message")
      "Welcome!"

      iex> I18n.t("hello_name", %{name: "John"})
      "Hello, John!"
  """
  def t(key, bindings \\ %{}) do
    ensure_server_started()
    I18nServer.t(@server, key, bindings)
  end

  @doc """
  Set the current locale.

  ## Examples

      iex> I18n.set_locale("fr")
      :ok

      iex> I18n.set_locale("invalid")
      {:error, :locale_not_available}
  """
  def set_locale(locale) do
    ensure_server_started()
    I18nServer.set_locale(@server, locale)
  end

  @doc """
  Get the current locale.

  ## Examples

      iex> I18n.get_locale()
      "en"
  """
  def get_locale do
    ensure_server_started()
    I18nServer.get_locale(@server)
  end

  @doc """
  Check if the current locale is right-to-left.

  ## Examples

      iex> I18n.set_locale("ar")
      iex> I18n.rtl?()
      true

      iex> I18n.set_locale("en")
      iex> I18n.rtl?()
      false
  """
  def rtl? do
    ensure_server_started()
    I18nServer.rtl?(@server)
  end

  @doc """
  Format a currency amount according to the current locale.

  ## Examples

      iex> I18n.format_currency(1234.56, "USD")
      "$1,234.56"

      iex> I18n.set_locale("fr")
      iex> I18n.format_currency(1234.56, "EUR")
      "1 234,56 €"
  """
  def format_currency(amount, currency_code)
      when is_number(amount) and is_binary(currency_code) do
    ensure_server_started()
    I18nServer.format_currency(@server, amount, currency_code)
  end

  @doc """
  Format a datetime according to the current locale.

  ## Examples

      iex> dt = DateTime.utc_now()
      iex> I18n.format_datetime(dt)
      "December 12, 2025 at 3:45 PM"
  """
  def format_datetime(datetime) when is_struct(datetime, DateTime) do
    ensure_server_started()
    I18nServer.format_datetime(@server, datetime)
  end

  @doc """
  Handle locale changed events.

  This is now handled internally by the server.
  """
  def handle_locale_changed({:locale_changed, _old, _new} = event) do
    # The server handles this internally now
    # This function exists for backward compatibility
    _ = event
    :ok
  end

  @doc """
  Clean up i18n resources.

  With GenServer, cleanup happens automatically when the server stops.
  """
  def cleanup do
    case Process.whereis(@server) do
      nil ->
        :ok

      pid ->
        # Use try/catch because the process might be stopped between
        # the whereis check and the stop call
        try do
          GenServer.stop(pid, :normal, 5000)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:normal, _} -> :ok
        end

        :ok
    end
  end

  @doc """
  Get all available locales.
  """
  def available_locales do
    ensure_server_started()
    I18nServer.available_locales(@server)
  end

  @doc """
  Add or update translations for a locale.

  ## Examples

      iex> I18n.add_translations("en", %{
      ...>   "new_key" => "New translation",
      ...>   "another_key" => "Another translation"
      ...> })
      :ok
  """
  def add_translations(locale, translations) when is_map(translations) do
    ensure_server_started()
    I18nServer.add_translations(@server, locale, translations)
  end

  # Private Functions

  @spec ensure_server_started(map()) :: any()
  defp ensure_server_started(config \\ %{}) do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      @server,
      fn -> GenServer.start(I18nServer, config, name: @server) end
    )
  end
end
