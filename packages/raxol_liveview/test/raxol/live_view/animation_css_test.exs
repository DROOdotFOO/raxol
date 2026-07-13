defmodule Raxol.LiveView.AnimationCSSTest do
  use ExUnit.Case, async: true

  alias Raxol.LiveView.TerminalBridge

  describe "animation_css/1" do
    test "generates CSS transition for element with opacity hint" do
      elements = [
        %{
          id: "panel",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :ease_out_cubic,
              delay_ms: 0
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="panel"])
      assert css =~ "opacity 300ms"
      assert css =~ "cubic-bezier(0.215, 0.61, 0.355, 1)"
      assert css =~ "0ms"
    end

    test "generates multiple transitions for element with multiple hints" do
      elements = [
        %{
          id: "card",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :ease_out_cubic,
              delay_ms: 0
            },
            %{property: :color, duration_ms: 200, easing: :linear, delay_ms: 50}
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "opacity 300ms"
      assert css =~ "color 200ms linear 50ms"
    end

    test "generates rules for multiple elements" do
      elements = [
        %{
          id: "header",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 500,
              easing: :linear,
              delay_ms: 0
            }
          ]
        },
        %{
          id: "body",
          type: :box,
          animation_hints: [
            %{
              property: :bg,
              duration_ms: 300,
              easing: :ease_in_out_cubic,
              delay_ms: 100
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="header"])
      assert css =~ ~s([data-raxol-id="body"])
      assert css =~ "background-color 300ms"
    end

    test "always includes prefers-reduced-motion media query" do
      elements = [
        %{
          id: "panel",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :linear,
              delay_ms: 0
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "@media (prefers-reduced-motion: reduce)"
      assert css =~ "transition-duration: 0.01ms !important"
    end

    test "returns empty string when no elements have hints" do
      elements = [
        %{id: "plain", type: :box, children: []},
        %{type: :text, content: "no hints"}
      ]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "returns empty string for empty list" do
      assert TerminalBridge.animation_css([]) == ""
    end

    test "skips elements without an id" do
      elements = [
        %{
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :linear,
              delay_ms: 0
            }
          ]
        }
      ]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "skips hints with unmappable properties" do
      elements = [
        %{
          id: "widget",
          type: :box,
          animation_hints: [
            %{
              property: :custom_thing,
              duration_ms: 300,
              easing: :linear,
              delay_ms: 0
            }
          ]
        }
      ]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "collects hints from nested children" do
      elements = [
        %{
          type: :box,
          children: [
            %{
              id: "nested",
              type: :text,
              animation_hints: [
                %{
                  property: :opacity,
                  duration_ms: 200,
                  easing: :linear,
                  delay_ms: 0
                }
              ]
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="nested"])
      assert css =~ "opacity 200ms"
    end

    test "handles delay_ms correctly" do
      elements = [
        %{
          id: "delayed",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :ease_in_expo,
              delay_ms: 150
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "150ms"
      assert css =~ "cubic-bezier(0.95, 0.05, 0.795, 0.035)"
    end

    test "wraps output in style tags" do
      elements = [
        %{
          id: "el",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 100,
              easing: :linear,
              delay_ms: 0
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert String.starts_with?(css, "<style>")
      assert String.ends_with?(css, "</style>")
    end

    test "generates border_beam CSS with conic-gradient for beam hint" do
      elements = [
        %{
          id: "beam-panel",
          type: :box,
          animation_hints: [
            %{
              type: :border_beam,
              variant: :ocean,
              size: :full,
              strength: 0.8,
              duration_ms: 2000,
              brightness: 1.3,
              saturation: 1.2,
              hue_range: 30,
              active: true,
              static_colors: false
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "conic-gradient"
      assert css =~ "beam-panel"
      assert css =~ "mask-composite"
    end

    test "border_beam hints coexist with regular transition hints" do
      elements = [
        %{
          id: "combo",
          type: :box,
          animation_hints: [
            %{
              property: :opacity,
              duration_ms: 300,
              easing: :linear,
              delay_ms: 0
            },
            %{
              type: :border_beam,
              variant: :colorful,
              size: :full,
              strength: 0.8,
              duration_ms: 2000,
              brightness: 1.3,
              saturation: 1.2,
              hue_range: 30,
              active: true,
              static_colors: false
            }
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "opacity 300ms"
      assert css =~ "conic-gradient"
    end
  end

  describe "animation_css/1 overflow-anchor" do
    test "emits overflow-anchor: auto for :auto setting" do
      elements = [%{id: "log", type: :box, overflow_anchor: :auto}]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="log"] { overflow-anchor: auto; })
    end

    test "emits overflow-anchor: none for :none setting" do
      elements = [%{id: "log", type: :box, overflow_anchor: :none}]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="log"] { overflow-anchor: none; })
    end

    test "emits rules for multiple elements with different anchor settings" do
      elements = [
        %{id: "chat", type: :box, overflow_anchor: :auto},
        %{id: "frozen", type: :box, overflow_anchor: :none}
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="chat"] { overflow-anchor: auto; })
      assert css =~ ~s([data-raxol-id="frozen"] { overflow-anchor: none; })
    end

    test "collects overflow-anchor settings from nested children" do
      elements = [
        %{
          type: :box,
          children: [
            %{id: "nested-log", type: :box, overflow_anchor: :auto}
          ]
        }
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ ~s([data-raxol-id="nested-log"] { overflow-anchor: auto; })
    end

    test "skips elements without an id" do
      elements = [%{type: :box, overflow_anchor: :auto}]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "skips elements with an unrecognized overflow_anchor value" do
      elements = [%{id: "weird", type: :box, overflow_anchor: :sometimes}]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "emits no CSS for elements without an overflow_anchor setting" do
      elements = [%{id: "plain", type: :box, children: []}]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "coexists with animation transitions in the same style block" do
      elements = [
        %{
          id: "panel",
          type: :box,
          animation_hints: [
            %{property: :opacity, duration_ms: 300, easing: :linear, delay_ms: 0}
          ]
        },
        %{id: "log", type: :box, overflow_anchor: :auto}
      ]

      css = TerminalBridge.animation_css(elements)

      assert css =~ "opacity 300ms"
      assert css =~ ~s([data-raxol-id="log"] { overflow-anchor: auto; })
      assert String.starts_with?(css, "<style>")
      assert String.ends_with?(css, "</style>")
    end
  end
end
