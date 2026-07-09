defmodule Raxol.Terminal.SearchManager do
  @moduledoc """
  Manages terminal search operations including text search, pattern matching, and search history.
  This module is responsible for handling all search-related operations in the terminal.
  """

  alias Raxol.Terminal.SearchBuffer

  @doc """
  Gets the search buffer instance.
  Returns the search buffer.
  """
  def get_buffer(emulator) do
    emulator.search_buffer
  end

  @doc """
  Updates the search buffer instance.
  Returns the updated emulator.
  """
  def update_buffer(emulator, buffer) do
    %{emulator | search_buffer: buffer}
  end

  @doc """
  Starts a new search with the given pattern.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def start_search(emulator, pattern) do
    case SearchBuffer.start_search(emulator.search_buffer, pattern) do
      {:ok, new_buffer} ->
        {:ok, update_buffer(emulator, new_buffer)}

      {:error, reason} ->
        {:error, "Failed to start search: #{inspect(reason)}"}
    end
  end

  @doc """
  Finds the next match in the search.
  Returns {:ok, updated_emulator, match} or {:error, reason}.
  """
  def find_next(emulator) do
    case SearchBuffer.find_next(emulator.search_buffer) do
      {:ok, new_buffer, match} ->
        {:ok, update_buffer(emulator, new_buffer), match}

      {:error, reason} ->
        {:error, "Failed to find next match: #{inspect(reason)}"}
    end
  end

  @doc """
  Finds the previous match in the search.
  Returns {:ok, updated_emulator, match} or {:error, reason}.
  """
  def find_previous(emulator) do
    case SearchBuffer.find_previous(emulator.search_buffer) do
      {:ok, new_buffer, match} ->
        {:ok, update_buffer(emulator, new_buffer), match}

      {:error, reason} ->
        {:error, "Failed to find previous match: #{inspect(reason)}"}
    end
  end

  @doc """
  Gets the current search pattern.
  Returns the current pattern.
  """
  def get_pattern(emulator) do
    SearchBuffer.get_pattern(emulator.search_buffer)
  end

  @doc """
  Sets the search options.
  Returns the updated emulator.
  """
  def set_options(emulator, options) do
    buffer = SearchBuffer.set_options(emulator.search_buffer, options)
    update_buffer(emulator, buffer)
  end

  @doc """
  Gets the current search options.
  Returns the current options.
  """
  def get_options(emulator) do
    SearchBuffer.get_options(emulator.search_buffer)
  end

  @doc """
  Gets all matches in the current search.
  Returns the list of matches.
  """
  def get_all_matches(emulator) do
    SearchBuffer.get_all_matches(emulator.search_buffer)
  end

  @doc """
  Gets the current match index.
  Returns the current index.
  """
  def get_current_index(emulator) do
    SearchBuffer.get_current_index(emulator.search_buffer)
  end

  @doc """
  Gets the total number of matches.
  Returns the number of matches.
  """
  def get_match_count(emulator) do
    SearchBuffer.get_match_count(emulator.search_buffer)
  end

  @doc """
  Highlights all matches in the current view.
  Returns the updated emulator.
  """
  def highlight_matches(emulator) do
    buffer = SearchBuffer.highlight_matches(emulator.search_buffer)
    update_buffer(emulator, buffer)
  end

  @doc """
  Clears the current search.
  Returns the updated emulator.
  """
  def clear_search(emulator) do
    buffer = SearchBuffer.clear(emulator.search_buffer)
    update_buffer(emulator, buffer)
  end

  @doc """
  Gets the search history.
  Returns the list of recent search patterns.
  """
  def get_search_history(emulator) do
    SearchBuffer.get_search_history(emulator.search_buffer)
  end

  @doc """
  Adds a pattern to the search history.
  Returns the updated emulator.
  """
  def add_to_history(emulator, pattern) do
    buffer = SearchBuffer.add_to_history(emulator.search_buffer, pattern)
    update_buffer(emulator, buffer)
  end

  @doc """
  Clears the search history.
  Returns the updated emulator.
  """
  def clear_history(emulator) do
    buffer = SearchBuffer.clear_history(emulator.search_buffer)
    update_buffer(emulator, buffer)
  end
end
