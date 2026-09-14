defmodule Raxol.Animation.EasingTest do
  use ExUnit.Case

  alias Raxol.Animation.Easing

  describe "Easing Functions" do
    test ~c"linear easing" do
      assert Easing.linear(0.0) == 0.0
      assert Easing.linear(0.5) == 0.5
      assert Easing.linear(1.0) == 1.0
    end

    test ~c"ease_in_quad" do
      assert Easing.ease_in_quad(0.0) == 0.0
      assert_in_delta Easing.ease_in_quad(0.5), 0.25, 0.001
      assert Easing.ease_in_quad(1.0) == 1.0
    end

    test ~c"ease_out_quad" do
      assert Easing.ease_out_quad(0.0) == 0.0
      assert_in_delta Easing.ease_out_quad(0.5), 0.75, 0.001
      assert Easing.ease_out_quad(1.0) == 1.0
    end

    test ~c"ease_in_out_quad" do
      assert Easing.ease_in_out_quad(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_quad(0.25), 0.125, 0.001
      assert_in_delta Easing.ease_in_out_quad(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_quad(0.75), 0.875, 0.001
      assert Easing.ease_in_out_quad(1.0) == 1.0
    end

    test ~c"ease_in_cubic" do
      assert Easing.ease_in_cubic(0.0) == 0.0
      assert_in_delta Easing.ease_in_cubic(0.5), 0.125, 0.001
      assert Easing.ease_in_cubic(1.0) == 1.0
    end

    test ~c"ease_out_cubic" do
      assert Easing.ease_out_cubic(0.0) == 0.0
      assert_in_delta Easing.ease_out_cubic(0.5), 0.875, 0.001
      assert Easing.ease_out_cubic(1.0) == 1.0
    end

    test ~c"ease_in_out_cubic" do
      assert Easing.ease_in_out_cubic(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_cubic(0.25), 0.0625, 0.001
      assert_in_delta Easing.ease_in_out_cubic(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_cubic(0.75), 0.9375, 0.001
      assert Easing.ease_in_out_cubic(1.0) == 1.0
    end

    test ~c"ease_in_quart" do
      assert Easing.ease_in_quart(0.0) == 0.0
      assert_in_delta Easing.ease_in_quart(0.5), 0.0625, 0.001
      assert Easing.ease_in_quart(1.0) == 1.0
    end

    test ~c"ease_out_quart" do
      assert Easing.ease_out_quart(0.0) == 0.0
      assert_in_delta Easing.ease_out_quart(0.5), 0.9375, 0.001
      assert Easing.ease_out_quart(1.0) == 1.0
    end

    test ~c"ease_in_out_quart" do
      assert Easing.ease_in_out_quart(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_quart(0.25), 0.03125, 0.001
      assert_in_delta Easing.ease_in_out_quart(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_quart(0.75), 0.96875, 0.001
      assert Easing.ease_in_out_quart(1.0) == 1.0
    end

    test ~c"ease_in_quint" do
      assert Easing.ease_in_quint(0.0) == 0.0
      assert_in_delta Easing.ease_in_quint(0.5), 0.03125, 0.001
      assert Easing.ease_in_quint(1.0) == 1.0
    end

    test ~c"ease_out_quint" do
      assert Easing.ease_out_quint(0.0) == 0.0
      assert_in_delta Easing.ease_out_quint(0.5), 0.96875, 0.001
      assert Easing.ease_out_quint(1.0) == 1.0
    end

    test ~c"ease_in_out_quint" do
      assert Easing.ease_in_out_quint(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_quint(0.25), 0.015625, 0.001
      assert_in_delta Easing.ease_in_out_quint(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_quint(0.75), 0.984375, 0.001
      assert Easing.ease_in_out_quint(1.0) == 1.0
    end

    test ~c"ease_in_sine" do
      assert Easing.ease_in_sine(0.0) == 0.0
      assert_in_delta Easing.ease_in_sine(0.5), 0.292893, 0.001
      assert Easing.ease_in_sine(1.0) == 1.0
    end

    test ~c"ease_out_sine" do
      assert Easing.ease_out_sine(0.0) == 0.0
      assert_in_delta Easing.ease_out_sine(0.5), 0.707107, 0.001
      assert Easing.ease_out_sine(1.0) == 1.0
    end

    test ~c"ease_in_out_sine" do
      assert Easing.ease_in_out_sine(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_sine(0.25), 0.146447, 0.001
      assert_in_delta Easing.ease_in_out_sine(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_sine(0.75), 0.853553, 0.001
      assert Easing.ease_in_out_sine(1.0) == 1.0
    end

    test ~c"ease_in_expo" do
      assert Easing.ease_in_expo(0.0) == 0.0
      assert_in_delta Easing.ease_in_expo(0.5), 0.03125, 0.001
      assert Easing.ease_in_expo(1.0) == 1.0
    end

    test ~c"ease_out_expo" do
      assert Easing.ease_out_expo(0.0) == 0.0
      assert_in_delta Easing.ease_out_expo(0.5), 0.96875, 0.001
      assert Easing.ease_out_expo(1.0) == 1.0
    end

    test ~c"ease_in_out_expo" do
      assert Easing.ease_in_out_expo(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_expo(0.25), 0.015625, 0.001
      assert_in_delta Easing.ease_in_out_expo(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_expo(0.75), 0.984375, 0.001
      assert Easing.ease_in_out_expo(1.0) == 1.0
    end

    test ~c"ease_in_circ" do
      assert Easing.ease_in_circ(0.0) == 0.0
      assert_in_delta Easing.ease_in_circ(0.5), 0.133975, 0.001
      assert Easing.ease_in_circ(1.0) == 1.0
    end

    test ~c"ease_out_circ" do
      assert Easing.ease_out_circ(0.0) == 0.0
      assert_in_delta Easing.ease_out_circ(0.5), 0.866025, 0.001
      assert Easing.ease_out_circ(1.0) == 1.0
    end

    test ~c"ease_in_out_circ" do
      assert Easing.ease_in_out_circ(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_circ(0.25), 0.066987, 0.001
      assert_in_delta Easing.ease_in_out_circ(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_circ(0.75), 0.933013, 0.001
      assert Easing.ease_in_out_circ(1.0) == 1.0
    end

    test ~c"ease_in_back" do
      assert Easing.ease_in_back(0.0) == 0.0
      assert_in_delta Easing.ease_in_back(0.5), -0.0876975, 0.001
      assert Easing.ease_in_back(1.0) == 1.0
    end

    test ~c"ease_out_back" do
      assert Easing.ease_out_back(0.0) == 0.0
      assert_in_delta Easing.ease_out_back(0.5), 1.0876975, 0.001
      assert Easing.ease_out_back(1.0) == 1.0
    end

    test ~c"ease_in_out_back" do
      assert Easing.ease_in_out_back(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_back(0.25), -0.04384875, 0.001
      assert_in_delta Easing.ease_in_out_back(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_back(0.75), 1.04384875, 0.001
      assert Easing.ease_in_out_back(1.0) == 1.0
    end

    test ~c"ease_in_elastic" do
      assert Easing.ease_in_elastic(0.0) == 0.0
      assert_in_delta Easing.ease_in_elastic(0.5), -0.015625, 0.001
      assert Easing.ease_in_elastic(1.0) == 1.0
    end

    test ~c"ease_out_elastic" do
      assert Easing.ease_out_elastic(0.0) == 0.0
      assert_in_delta Easing.ease_out_elastic(0.5), 1.015625, 0.001
      assert Easing.ease_out_elastic(1.0) == 1.0
    end

    test ~c"ease_in_out_elastic" do
      assert Easing.ease_in_out_elastic(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_elastic(0.25), -0.0078125, 0.001
      assert_in_delta Easing.ease_in_out_elastic(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_elastic(0.75), 1.0078125, 0.001
      assert Easing.ease_in_out_elastic(1.0) == 1.0
    end

    test ~c"ease_in_bounce" do
      assert Easing.ease_in_bounce(0.0) == 0.0
      assert_in_delta Easing.ease_in_bounce(0.5), 0.234375, 0.001
      assert Easing.ease_in_bounce(1.0) == 1.0
    end

    test ~c"ease_out_bounce" do
      assert Easing.ease_out_bounce(0.0) == 0.0
      assert_in_delta Easing.ease_out_bounce(0.5), 0.765625, 0.001
      assert Easing.ease_out_bounce(1.0) == 1.0
    end

    test ~c"ease_in_out_bounce" do
      assert Easing.ease_in_out_bounce(0.0) == 0.0
      assert_in_delta Easing.ease_in_out_bounce(0.25), 0.1171875, 0.001
      assert_in_delta Easing.ease_in_out_bounce(0.5), 0.5, 0.001
      assert_in_delta Easing.ease_in_out_bounce(0.75), 0.8828125, 0.001
      assert Easing.ease_in_out_bounce(1.0) == 1.0
    end
  end

  # Deleted describe "Performance": "easing functions meet performance
  # requirements" timed five arithmetic calls per function against a 1ms
  # ceiling -- microseconds of work measured with a bound a single
  # scheduler hiccup breaks. Easing is pure arithmetic; `bench/` owns any
  # budget for it, and the value assertions above already pin every
  # function's output for all five inputs.
end
