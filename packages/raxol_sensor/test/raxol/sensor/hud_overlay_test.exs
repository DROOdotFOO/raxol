defmodule Raxol.Sensor.HUDOverlayTest do
  use ExUnit.Case, async: true

  alias Raxol.Sensor.HUDOverlay

  describe "fused updates" do
    test "renders layout and sends cells to buffer_pid" do
      layout = [
        %{
          widget: :gauge,
          region: {0, 0, 30, 1},
          sensor_id: :temp,
          opts: [label: "TEMP"]
        }
      ]

      {:ok, pid} =
        HUDOverlay.start_link(
          name: nil,
          buffer_pid: self(),
          layout: layout
        )

      fused = %{
        sensors: %{
          temp: %{
            values: %{value: 75.0},
            quality: 1.0,
            latest_timestamp: 0,
            reading_count: 1,
            alerts: []
          }
        },
        fused_at: 0
      }

      send(pid, {:fused_update, fused})

      assert_receive {:hud_cells, cells}, 200
      assert [_ | _] = cells
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "handles missing sensor data gracefully" do
      layout = [
        %{
          widget: :gauge,
          region: {0, 0, 30, 1},
          sensor_id: :nonexistent,
          opts: []
        }
      ]

      {:ok, pid} =
        HUDOverlay.start_link(
          name: nil,
          buffer_pid: self(),
          layout: layout
        )

      fused = %{sensors: %{}, fused_at: 0}
      send(pid, {:fused_update, fused})

      assert_receive {:hud_cells, []}, 200
    end

    test "no buffer_pid means no send" do
      layout = [
        %{
          widget: :gauge,
          region: {0, 0, 30, 1},
          sensor_id: :temp,
          opts: []
        }
      ]

      {:ok, pid} =
        HUDOverlay.start_link(
          name: nil,
          buffer_pid: nil,
          layout: layout
        )

      fused = %{
        sensors: %{
          temp: %{
            values: %{value: 50.0},
            quality: 1.0,
            latest_timestamp: 0,
            reading_count: 1,
            alerts: []
          }
        },
        fused_at: 0
      }

      send(pid, {:fused_update, fused})
      Process.sleep(20)
      refute_received {:hud_cells, _}
    end

    test "multiple widgets in layout" do
      layout = [
        %{widget: :gauge, region: {0, 0, 30, 1}, sensor_id: :temp, opts: [label: "T"]},
        %{widget: :threat, region: {0, 1, 30, 1}, sensor_id: :prox, opts: []}
      ]

      {:ok, pid} =
        HUDOverlay.start_link(
          name: nil,
          buffer_pid: self(),
          layout: layout
        )

      fused = %{
        sensors: %{
          temp: %{
            values: %{value: 50.0},
            quality: 1.0,
            latest_timestamp: 0,
            reading_count: 1,
            alerts: []
          },
          prox: %{
            values: %{level: :high, bearing: 45},
            quality: 1.0,
            latest_timestamp: 0,
            reading_count: 1,
            alerts: []
          }
        },
        fused_at: 0
      }

      send(pid, {:fused_update, fused})

      assert_receive {:hud_cells, cells}, 200
      # Should have cells from both widgets
      assert length(cells) > 30
    end
  end
end
