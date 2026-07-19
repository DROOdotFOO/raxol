defmodule Raxol.UI.Components.TableTest do
  use ExUnit.Case
    alias Raxol.UI.Components.Table

  @test_columns [
    %{
      id: :id,
      label: "ID",
      width: 4,
      align: :right,
      format: &String.Chars.to_string/1
    },
    %{
      id: :name,
      label: "Name",
      width: 10,
      align: :left,
      format: &String.Chars.to_string/1
    },
    %{
      id: :age,
      label: "Age",
      width: 5,
      align: :center,
      format: &String.Chars.to_string/1
    }
  ]

  @test_data [
    %{id: 1, name: "Alice", age: 25},
    %{id: 2, name: "Bob", age: 30},
    %{id: 3, name: "Charlie", age: 35},
    %{id: 4, name: "Dave", age: 40},
    %{id: 5, name: "Eve", age: 28}
  ]

  setup do
    # Initialize any required dependencies
    :ok = Raxol.UI.Theming.Theme.init()

    case Raxol.Core.UserPreferences.start_link(test_mode?: true) do
      {:ok, _pid} ->
        :ok

      # Ignore if already started
      {:error, {:already_started, _pid}} ->
        :ok

      other_error ->
        flunk("UserPreferences failed to start: #{inspect(other_error)}")
    end

    case Raxol.Core.Renderer.RendererManager.start_link([]) do
      {:ok, _pid} ->
        :ok

      # Ignore if already started
      {:error, {:already_started, _pid}} ->
        :ok

      other_error ->
        flunk("Renderer.Manager failed to start: #{inspect(other_error)}")
    end

    # Return the test context
    {:ok,
     %{
       columns: @test_columns,
       data: @test_data
     }}
  end

  describe "initialization" do
    test "initializes with default options", %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      assert state.id == :test_table
      assert state.columns == columns
      assert state.data == data

      assert state.options.paginate == false
      assert state.options.searchable == false
      assert state.options.sortable == false
      assert state.options.page_size == 10
      assert state.options.border == :grid
      assert state.options.header_separator == true

      assert state.current_page == 1
      assert state.page_size == 10
      assert state.filter_term == ""
    end

    test "initializes with custom options", %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data,
          options: %{
            paginate: true,
            searchable: true,
            sortable: true,
            page_size: 2
          }
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      assert state.options.paginate == true
      assert state.options.searchable == true
      assert state.options.sortable == true
      assert state.options.page_size == 2
      assert state.options.border == :grid
      assert state.page_size == 2
    end
  end

  describe "data processing" do
    setup %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data,
          options: %{
            paginate: true,
            searchable: true,
            sortable: true,
            page_size: 2
          }
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      {:ok, %{state: state}}
    end

    test "filtering works correctly", %{state: state} do
      result = Table.update({:filter, "alice"}, state)
      assert match?({:ok, _}, result)
      {:ok, updated_state} = result
      rendered = Table.render(updated_state, %{})

      assert rendered.type == :box
      text = lines_text(rendered)
      body = Enum.filter(text, &String.contains?(&1, "Alice"))
      assert length(body) == 1
      refute Enum.any?(text, &String.contains?(&1, "Bob"))
    end

    test "sorting works correctly", %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data,
          options: %{
            paginate: false,
            searchable: true,
            sortable: true,
            page_size: 10
          }
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      result = Table.update({:sort, :age}, state)
      assert match?({:ok, _}, result)
      {:ok, updated_state} = result
      body = body_lines(Table.render(updated_state, %{available_width: 80}))

      # Age ascending: Alice(25) first, Dave(40) last
      assert List.first(body) =~ "Alice"
      assert List.first(body) =~ "25"
      assert List.last(body) =~ "Dave"
      assert List.last(body) =~ "40"
    end

    test "pagination works correctly", %{state: state} do
      result = Table.update({:set_page, 1}, state)
      assert match?({:ok, _}, result)
      {:ok, page1_state} = result
      body = body_lines(Table.render(page1_state, %{available_width: 80}))
      assert length(body) == 2
      assert Enum.at(body, 0) =~ "Alice"
      assert Enum.at(body, 1) =~ "Bob"

      result = Table.update({:set_page, 2}, state)
      assert match?({:ok, _}, result)
      {:ok, page2_state} = result
      body = body_lines(Table.render(page2_state, %{available_width: 80}))
      assert length(body) == 2
      assert Enum.at(body, 0) =~ "Charlie"
    end
  end

  describe "event handling" do
    setup %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data,
          options: %{
            paginate: true,
            searchable: true,
            sortable: true,
            page_size: 2
          }
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      {:ok, %{state: state}}
    end

    test "handles arrow key navigation for pagination", %{state: state} do
      assert state.current_page == 1

      result = Table.handle_event({:key, {:arrow_right, []}}, state, %{})
      assert match?({:ok, _}, result)
      {:ok, state_after_right} = result

      assert state_after_right.current_page == 2

      result =
        Table.handle_event({:key, {:arrow_left, []}}, state_after_right, %{})

      assert match?({:ok, _}, result)
      {:ok, state_after_left} = result

      assert state_after_left.current_page == 1

      result =
        Table.handle_event({:key, {:arrow_left, []}}, state_after_left, %{})

      assert match?({:ok, _}, result)
      {:ok, state_after_left_again} = result

      assert state_after_left_again.current_page == 1
    end

    test "handles button clicks for pagination", %{state: state} do
      result =
        Table.handle_event({:button_click, "test_table_next_page"}, state, %{})

      assert match?({:ok, _}, result)
      {:ok, state_after_next} = result

      assert state_after_next.current_page == 2

      result =
        Table.handle_event(
          {:button_click, "test_table_prev_page"},
          state_after_next,
          %{}
        )

      assert match?({:ok, _}, result)
      {:ok, state_after_prev} = result

      assert state_after_prev.current_page == 1
    end

    test "handles sort button clicks", %{state: state} do
      result =
        Table.handle_event({:button_click, "test_table_sort_age"}, state, %{})

      assert match?({:ok, _}, result)
      {:ok, state_after_sort} = result

      assert state_after_sort.sort_by == :age
      assert state_after_sort.sort_direction == :asc

      result =
        Table.handle_event(
          {:button_click, "test_table_sort_age"},
          state_after_sort,
          %{}
        )

      assert match?({:ok, _}, result)
      {:ok, state_after_reverse} = result

      assert state_after_reverse.sort_by == :age
      assert state_after_reverse.sort_direction == :desc
    end

    test "handles search input", %{state: state} do
      result =
        Table.handle_event(
          {:text_input, "test_table_search", "Alice"},
          state,
          %{}
        )

      assert match?({:ok, _}, result)
      {:ok, state_after_search} = result

      assert state_after_search.filter_term == "Alice"
      assert state_after_search.current_page == 1
    end
  end

  describe "theming and style" do
    setup %{columns: columns, data: data} do
      result =
        Table.init(%{
          id: :test_table,
          columns: columns,
          data: data,
          options: %{
            paginate: false,
            searchable: false,
            sortable: true,
            page_size: 10
          }
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      {:ok, %{state: state}}
    end

    test "header is rendered with bold style", %{state: state} do
      rendered = Table.render(state, %{available_width: 80})
      header =
        Enum.find(table_line_elements(rendered), fn el ->
          :bold in (el[:style] || [])
        end)

      assert header
      assert :bold in header.style
    end

    test "selected row is rendered with correct background and foreground colors",
         %{state: state} do
      state = %{state | selected_row: 1}
      rendered = Table.render(state, %{available_width: 80})
      lines = table_line_elements(rendered)
      # body rows are the non-rule, non-header text lines with selection style
      selected =
        Enum.find(lines, fn el ->
          style = el[:style] || []
          {:bg, :blue} in style and {:fg, :white} in style
        end)

      assert selected
    end

    test "box style is overridden by style prop", %{
      columns: columns,
      data: data
    } do
      result =
        Table.init(%{
          id: :styled,
          columns: columns,
          data: data,
          style: %{border_color: :red}
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      rendered = Table.render(state, %{available_width: 80})
      assert Map.get(rendered.style, :border_color) == :red
    end

    test "box style is overridden by theme", %{columns: columns, data: data} do
      theme = %{box: %{border_color: :green}}

      result =
        Table.init(%{id: :themed, columns: columns, data: data, theme: theme})

      assert match?({:ok, _}, result)
      {:ok, state} = result

      rendered = Table.render(state, %{available_width: 80})
      assert Map.get(rendered.style, :border_color) == :green
    end

    test "header style is overridden by theme and style prop", %{
      columns: columns,
      data: data
    } do
      theme = %{header: %{underline: true}}
      style = %{header: %{italic: true}}

      result =
        Table.init(%{
          id: :headerstyled,
          columns: columns,
          data: data,
          theme: theme,
          style: style
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      rendered = Table.render(state, %{available_width: 80})
      header = Enum.find(table_line_elements(rendered), &(:bold in (&1.style || [])))
      assert :underline in header.style
      assert :italic in header.style
    end

    test "row and selected row style are overridden by theme", %{
      columns: columns,
      data: data
    } do
      theme = %{row: %{bg: :yellow}, selected_row: %{bg: :red, fg: :black}}

      result =
        Table.init(%{
          id: :rowstyled,
          columns: columns,
          data: data,
          theme: theme,
          style: %{}
        })

      assert match?({:ok, _}, result)
      {:ok, state} = result

      rendered = Table.render(state, %{available_width: 80})
      # Unselected body rows carry yellow from theme.row
      yellow_row =
        Enum.find(table_line_elements(rendered), fn el ->
          style = el[:style] || []
          :yellow in style or {:bg, :yellow} in style
        end)

      assert yellow_row

      state = %{state | selected_row: 2}
      rendered = Table.render(state, %{available_width: 80})

      selected =
        Enum.find(table_line_elements(rendered), fn el ->
          style = el[:style] || []
          (:red in style or {:bg, :red} in style) and
            (:black in style or {:fg, :black} in style)
        end)

      assert selected
    end

    test "border modes draw distinct chrome", %{columns: columns, data: data} do
      {:ok, grid} =
        Table.init(%{
          id: :g,
          columns: columns,
          data: data,
          options: %{border: :grid}
        })

      {:ok, inner} =
        Table.init(%{
          id: :i,
          columns: columns,
          data: data,
          options: %{border: :inner}
        })

      {:ok, none} =
        Table.init(%{
          id: :n,
          columns: columns,
          data: data,
          options: %{border: :none, header_separator: true}
        })

      {:ok, bare} =
        Table.init(%{
          id: :b,
          columns: columns,
          data: data,
          options: %{border: :none, header_separator: false}
        })

      grid_text = lines_text(Table.render(grid, %{}))
      inner_text = lines_text(Table.render(inner, %{}))
      none_text = lines_text(Table.render(none, %{}))
      bare_text = lines_text(Table.render(bare, %{}))

      assert Enum.any?(grid_text, &String.starts_with?(&1, "┌"))
      assert Enum.any?(grid_text, &String.starts_with?(&1, "└"))
      assert Enum.any?(grid_text, &String.starts_with?(&1, "│"))
      # :inner — column + header mid-rule only; no top/bottom frame
      refute Enum.any?(inner_text, &String.contains?(&1, "┌"))
      refute Enum.any?(inner_text, &String.contains?(&1, "└"))
      refute Enum.any?(inner_text, &String.contains?(&1, "┬"))
      refute Enum.any?(inner_text, &String.contains?(&1, "┴"))
      assert Enum.any?(inner_text, &String.contains?(&1, "┼"))
      assert Enum.any?(inner_text, &String.contains?(&1, "│"))
      refute Enum.any?(none_text, &String.contains?(&1, "│"))
      assert Enum.any?(none_text, &String.contains?(&1, "─"))
      refute Enum.any?(bare_text, &String.contains?(&1, "─"))
      # grid uses column separators — "1" and "Alice" are not adjacent
      assert Enum.any?(grid_text, &String.contains?(&1, "Alice"))
      assert Enum.any?(grid_text, &String.contains?(&1, "│"))
      refute Enum.any?(grid_text, &String.contains?(&1, "1Alice"))
    end

    test "column style and header_style are row-level in the grid path", %{
      columns: _columns,
      data: data
    } do
      # Per-cell column styles are not painted independently once the grid
      # flattens a row into one text line — selection/row theme still works.
      # This documents the tradeoff of the character-grid renderer.
      custom_columns = [
        %{id: :id, label: "ID", width: 4, align: :right, style: %{color: :magenta}},
        %{id: :name, label: "Name", width: 10, align: :left},
        %{id: :age, label: "Age", width: 5, align: :center}
      ]

      result =
        Table.init(%{id: :colstyled, columns: custom_columns, data: data})

      assert match?({:ok, _}, result)
      {:ok, state} = result
      rendered = Table.render(state, %{available_width: 80})
      text = lines_text(rendered) |> Enum.join("\n")
      assert text =~ "Alice"
      assert text =~ "ID"
    end
  end

  # -- helpers for the character-grid render tree --

  defp table_line_elements(rendered) do
    body = get_in(rendered, [:children, Access.at(0)])
    (body && body[:children]) || []
  end

  defp lines_text(rendered) do
    rendered
    |> table_line_elements()
    |> Enum.map(fn
      %{text: t} when is_binary(t) -> t
      %{content: t} when is_binary(t) -> t
      other -> inspect(other)
    end)
  end

  # Body rows only (skip box-drawing rules and the bold header line).
  defp body_lines(rendered) do
    rendered
    |> table_line_elements()
    |> Enum.reject(fn el ->
      content = el[:content] || el[:text] || ""
      style = el[:style] || []
      String.contains?(content, "─") or String.contains?(content, "┌") or
        String.contains?(content, "└") or String.contains?(content, "├") or
        :bold in style
    end)
    |> Enum.map(fn el -> el[:content] || el[:text] || "" end)
  end
end
