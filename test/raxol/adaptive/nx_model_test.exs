defmodule Raxol.Adaptive.NxModelTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Adaptive.NxModel

  setup do
    # Clear cached compiled model between tests (feature size may change)
    :persistent_term.erase({NxModel, :compiled})
    :ok
  rescue
    ArgumentError -> :ok
  end

  describe "actions/0" do
    test "returns 5 actions" do
      assert length(NxModel.actions()) == 5
      assert :hide in NxModel.actions()
      assert :show in NxModel.actions()
      assert :expand in NxModel.actions()
      assert :shrink in NxModel.actions()
      assert :none in NxModel.actions()
    end
  end

  describe "build_model/0" do
    test "returns an Axon model" do
      model = NxModel.build_model()
      assert %Axon{} = model
    end
  end

  describe "init_params/0" do
    test "returns a map of model parameters" do
      params = NxModel.init_params()
      assert is_map(params)
      assert map_size(params) > 0
    end
  end

  describe "predict/2" do
    test "returns probabilities summing to ~1 per row" do
      params = NxModel.init_params()

      features =
        Nx.tensor([[0.5, 1.0, 0.0, 0.1, 0.0, 0.0, 0.0, 0.0, 0.3, 0.0]],
          type: :f32
        )

      result = NxModel.predict(params, features)

      assert {1, 5} == Nx.shape(result)
      sum = result |> Nx.sum() |> Nx.to_number()
      assert_in_delta sum, 1.0, 0.01
    end

    test "handles batch of panes" do
      params = NxModel.init_params()

      features =
        Nx.tensor(
          [
            [0.6, 1.0, 0.0, 0.05, 0.2, 0.1, 0.5, 0.0, 0.3, 0.0],
            [0.3, 0.0, 0.0, 0.05, 0.1, 0.0, 0.3, 0.0, 0.3, 0.5],
            [0.1, 0.0, 1.0, 0.05, 0.0, 0.0, 0.2, 0.0, 0.3, 1.0]
          ],
          type: :f32
        )

      result = NxModel.predict(params, features)

      assert {3, 5} == Nx.shape(result)
    end
  end

  describe "extract_features/2" do
    test "extracts features from aggregate" do
      aggregate = %{
        pane_dwell_times: %{panel_a: 6000, panel_b: 3000, panel_c: 1000},
        avg_alert_response_ms: 2000.0,
        least_used_panes: [:panel_c],
        scroll_frequency: %{panel_a: 5},
        scroll_velocity: %{panel_a: 2.0},
        command_concentration: %{panel_a: 3, panel_b: 1},
        takeover_duration_ms: %{}
      }

      pane_ids = [:panel_a, :panel_b, :panel_c]
      {features, ids} = NxModel.extract_features(aggregate, pane_ids)

      assert ids == pane_ids
      assert {3, 10} == Nx.shape(features)

      # panel_a: dwell_pct=0.6, most=1.0, least=0.0, alert=0.2
      row_a = Nx.to_flat_list(features[0])
      assert_in_delta Enum.at(row_a, 0), 0.6, 0.01
      assert_in_delta Enum.at(row_a, 1), 1.0, 0.01
      assert_in_delta Enum.at(row_a, 2), 0.0, 0.01
      assert_in_delta Enum.at(row_a, 3), 0.2, 0.01
    end

    test "handles empty dwell times" do
      aggregate = %{
        pane_dwell_times: %{},
        avg_alert_response_ms: 0.0,
        least_used_panes: []
      }

      pane_ids = [:panel_a]
      {features, _ids} = NxModel.extract_features(aggregate, pane_ids)

      assert {1, 10} == Nx.shape(features)
      # first 4 features are all zeros
      row = Nx.to_flat_list(features[0])
      assert Enum.at(row, 0) == 0.0
      assert Enum.at(row, 1) == 0.0
      assert Enum.at(row, 2) == 0.0
      assert Enum.at(row, 3) == 0.0
    end
  end

  describe "action_to_one_hot/1" do
    test "encodes :hide as index 0" do
      result = NxModel.action_to_one_hot(:hide)
      assert Nx.to_flat_list(result) == [1.0, 0.0, 0.0, 0.0, 0.0]
    end

    test "encodes :none as index 4" do
      result = NxModel.action_to_one_hot(:none)
      assert Nx.to_flat_list(result) == [0.0, 0.0, 0.0, 0.0, 1.0]
    end

    test "encodes :expand as index 2" do
      result = NxModel.action_to_one_hot(:expand)
      assert Nx.to_flat_list(result) == [0.0, 0.0, 1.0, 0.0, 0.0]
    end

    test "unknown action defaults to :none" do
      result = NxModel.action_to_one_hot(:unknown)
      assert Nx.to_flat_list(result) == [0.0, 0.0, 0.0, 0.0, 1.0]
    end
  end

  describe "interpret_predictions/2" do
    test "picks highest-confidence non-none action" do
      # Simulate predictions: pane_a -> expand (idx 2), pane_b -> none (idx 4)
      predictions =
        Nx.tensor(
          [
            [0.05, 0.05, 0.7, 0.1, 0.1],
            [0.05, 0.05, 0.05, 0.05, 0.8]
          ],
          type: :f32
        )

      result = NxModel.interpret_predictions(predictions, [:pane_a, :pane_b])

      # pane_b is :none so excluded
      assert [{:pane_a, :expand, confidence}] = result
      assert_in_delta confidence, 0.7, 0.01
    end

    test "returns empty when all panes predict :none" do
      predictions =
        Nx.tensor([[0.1, 0.1, 0.1, 0.1, 0.6]], type: :f32)

      result = NxModel.interpret_predictions(predictions, [:pane_a])
      assert result == []
    end
  end

  describe "train/2" do
    @tag :slow
    test "trains model and returns params" do
      # Generate synthetic training data: high dwell -> expand
      zeros6 = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

      training_data =
        for _ <- 1..20 do
          features = Nx.tensor([[0.7, 1.0, 0.0, 0.05] ++ zeros6], type: :f32)
          label = NxModel.action_to_one_hot(:expand)
          {features, label}
        end ++
          for _ <- 1..20 do
            features = Nx.tensor([[0.03, 0.0, 1.0, 0.1] ++ zeros6], type: :f32)
            label = NxModel.action_to_one_hot(:hide)
            {features, label}
          end

      params = NxModel.train(training_data, epochs: 30)

      assert is_map(params)
      assert map_size(params) > 0

      # Verify the model learned the pattern
      high_dwell = Nx.tensor([[0.7, 1.0, 0.0, 0.05] ++ zeros6], type: :f32)
      preds = NxModel.predict(params, high_dwell)
      probs = Nx.to_flat_list(preds)

      # expand (index 2) should have highest or near-highest probability
      expand_prob = Enum.at(probs, 2)
      assert expand_prob > 0.2
    end
  end
end
