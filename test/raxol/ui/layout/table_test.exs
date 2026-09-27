defmodule Raxol.UI.Layout.TableTest do
  use ExUnit.Case, async: false

  alias Raxol.UI.Layout.Table

  describe "Column Width Calculation" do
    test "respects fixed column widths" do
      # Define a table element as it would come from Elements.table
      table_element = %{
        type: :table,
        attrs: %{
          id: :test_table,
          columns: [
            %{header: "Col A", key: :a, width: 10},
            %{header: "Col B", key: :b, width: 20}
            # Add other necessary attrs if needed by measure_and_position
          ],
          data: [%{a: "Data1", b: "Data2"}],
          # Basic style
          style: %{}
        }
      }

      # Define available space
      space = %{x: 0, y: 0, width: 80, height: 24}

      # Call the function under test
      result = Table.measure_and_position(table_element, space, [])

      # Assertions
      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Check if the calculated widths match the fixed widths defined in columns
      assert calculated_widths == [10, 20]

      # Assert on the final width/height of the positioned element
      # Total width = col_widths_sum + frame = (10 + 20) + 2 = 32
      # Total height = frame(2) + header(1) + rule(1) + data_rows(1) = 5
      # Assuming space (80x24) is large enough, final dimensions should match calculated ones.
      assert [%{width: final_width, height: final_height}] = result
      assert final_width == 32
      assert final_height == 5
    end

    test "clamps width when content exceeds available space" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :clamp_table,
          columns: [
            %{header: "Col A", key: :a, width: 20},
            %{header: "Col B", key: :b, width: 25},
            # Total width = 20+25+30 + 2 = 77
            %{header: "Col C", key: :c, width: 30}
          ],
          data: [%{a: 1, b: 2, c: 3}],
          style: %{}
        }
      }

      # Provide limited space
      space = %{x: 0, y: 0, width: 50, height: 10}

      result = Table.measure_and_position(table_element, space, [])

      # Assert on the final dimensions
      assert [
               %{
                 width: final_width,
                 height: final_height,
                 attrs: %{_col_widths: calculated_widths}
               }
             ] = result

      # Column widths themselves should still be the original ones
      assert calculated_widths == [20, 25, 30]
      # Final width should be clamped to space.width
      assert final_width == 50

      # Final height should be calculated (frame+header+rule+data = 2+1+1+1=5) and not clamped
      assert final_height == 5
    end

    test "calculates fallback widths when columns are missing" do
      # Table with no columns defined - should use fallback calculation
      table_element = %{
        type: :table,
        attrs: %{
          id: :fallback_table,
          # No columns defined
          data: [
            ["Name", "Age", "City"],
            ["Alice", "25", "New York"],
            ["Bob", "30", "Los Angeles"]
          ],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 3 columns based on data structure
      assert length(calculated_widths) == 3

      # Widths should be calculated based on content + padding
      # Column 1: "Alice" (5 chars) + 2 padding = 7
      # Column 2: "Age" (3 chars) + 2 padding = 5
      # Column 3: "Los Angeles" (11 chars) + 2 padding = 13
      # So max widths should be: 7, 5, 13
      assert calculated_widths == [7, 5, 13]

      # Total width should be sum of column widths + frame
      # 7 + 5 + 13 + 2 = 27
      assert [%{width: final_width}] = result
      assert final_width == 27
    end

    test "handles auto column widths correctly" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :auto_width_table,
          columns: [
            %{header: "Name", key: :name, width: :auto},
            %{header: "Age", key: :age, width: :auto},
            %{header: "Location", key: :location, width: :auto}
          ],
          data: [
            %{name: "Alice Johnson", age: "25", location: "New York"},
            %{name: "Bob Smith", age: "30", location: "Los Angeles"},
            %{name: "Charlie Brown", age: "35", location: "Chicago"}
          ],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 3 columns
      assert length(calculated_widths) == 3

      # Widths should be calculated based on content:
      # "Name" header (4) vs "Alice Johnson" (13) vs "Charlie Brown" (13) -> max 13 + 2 = 15
      # "Age" header (3) vs "25", "30", "35" (2 chars each) -> max 3 + 2 = 5
      # "Location" header (8) vs "New York" (8) vs "Los Angeles" (11)
      # vs "Chicago" (7) -> max 11 + 2 = 13
      assert calculated_widths == [15, 5, 13]

      # Total width should be sum of column widths + frame
      # 15 + 5 + 13 + 2 = 35
      assert [%{width: final_width}] = result
      assert final_width == 35
    end

    test "handles mixed fixed and auto column widths" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :mixed_width_table,
          columns: [
            %{header: "Name", key: :name, width: :auto},
            %{header: "Age", key: :age, width: 8},
            %{header: "Location", key: :location, width: :auto}
          ],
          data: [
            %{name: "Alice", age: "25", location: "New York"},
            %{name: "Bob", age: "30", location: "Los Angeles"}
          ],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 3 columns
      assert length(calculated_widths) == 3

      # Widths should be:
      # Name: "Name" (4) vs "Alice" (5) vs "Bob" (3) -> max 5 + 2 = 7
      # Age: fixed at 8
      # Location: "Location" (8) vs "New York" (8) vs "Los Angeles" (11) -> max 11 + 2 = 13
      assert calculated_widths == [7, 8, 13]

      # Total width should be sum of column widths + frame
      # 7 + 8 + 13 + 2 = 30
      assert [%{width: final_width}] = result
      assert final_width == 30
    end

    test "clamps height when content exceeds available space" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :height_clamp_table,
          columns: [
            %{header: "Name", key: :name, width: 10},
            %{header: "Value", key: :value, width: 10}
          ],
          data: [
            %{name: "Row 1", value: "A"},
            %{name: "Row 2", value: "B"},
            %{name: "Row 3", value: "C"},
            %{name: "Row 4", value: "D"},
            %{name: "Row 5", value: "E"}
          ],
          style: %{}
        }
      }

      # Provide limited height space
      space = %{x: 0, y: 0, width: 80, height: 4}

      result = Table.measure_and_position(table_element, space, [])

      assert [
               %{
                 width: final_width,
                 height: final_height,
                 attrs: %{_col_widths: calculated_widths}
               }
             ] = result

      # Column widths should be preserved
      assert calculated_widths == [10, 10]

      # Width should be calculated normally (10 + 10 + 2 = 22)
      assert final_width == 22

      # Height should be clamped to available space (4)
      # Content height would be: frame(2) + header(1) + rule(1) + data(5) = 9
      # But should be clamped to space.height = 4
      assert final_height == 4
    end

    test "handles empty data with columns" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :empty_data_table,
          columns: [
            %{header: "Name", key: :name, width: 10},
            %{header: "Age", key: :age, width: 8}
          ],
          # Empty data
          data: [],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 2 columns with fixed widths
      assert calculated_widths == [10, 8]

      # Height should be frame(2) + header(1) + rule(1) + data(0) = 4
      assert [%{height: final_height}] = result
      assert final_height == 4

      # Width should be sum of column widths + frame
      # 10 + 8 + 2 = 20
      assert [%{width: final_width}] = result
      assert final_width == 20
    end

    test "handles empty data without columns" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :empty_fallback_table,
          # Empty data, no columns
          data: [],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 0 columns when no data and no columns
      assert calculated_widths == []

      # Height should be 0 (nothing to frame: no header, no data)
      assert [%{height: final_height}] = result
      assert final_height == 0

      # Width should be 0 (no columns, no frame)
      assert [%{width: final_width}] = result
      assert final_width == 0
    end

    test "handles single column table" do
      table_element = %{
        type: :table,
        attrs: %{
          id: :single_column_table,
          columns: [
            %{header: "Name", key: :name, width: 15}
          ],
          data: [
            %{name: "Alice"},
            %{name: "Bob"}
          ],
          style: %{}
        }
      }

      space = %{x: 0, y: 0, width: 80, height: 24}

      result = Table.measure_and_position(table_element, space, [])

      assert [%{attrs: %{_col_widths: calculated_widths}}] = result

      # Should have 1 column
      assert calculated_widths == [15]

      # Width should be the column width + frame (15 + 2 = 17)
      assert [%{width: final_width}] = result
      assert final_width == 17

      # Height should be frame(2) + header(1) + rule(1) + data(2) = 6
      assert [%{height: final_height}] = result
      assert final_height == 6
    end
  end
end
