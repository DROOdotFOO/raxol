defmodule Raxol.MCP.StructuredScreenshotA11yTest do
  @moduledoc """
  End-to-end: the MCP `StructuredScreenshot` folds real Component a11y_node
  Providers (loaded here in the main app) into the widget summary. The raxol_mcp
  suite only sees the fallback path; this covers the Provider path.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.StructuredScreenshot

  test "Provider-derived role/label/state surface through the screenshot" do
    tree = %{
      type: :column,
      id: "form",
      children: [
        %{type: :checkbox, id: "agree", label: "Agree", checked: true},
        %{
          type: :button,
          id: "submit",
          attrs: %{label: "Submit", disabled: true}
        }
      ]
    }

    [summary] = StructuredScreenshot.from_view_tree(tree)
    [checkbox, button] = summary.children

    assert checkbox.role == :checkbox
    assert checkbox.label == "Agree"
    assert checkbox.state == %{checked?: true}

    assert button.role == :button
    assert button.label == "Submit"
    assert button.state == %{disabled?: true}
  end

  test "nested Provider dispatch: modal dialog wraps its content controls" do
    tree = %{
      type: :modal,
      id: "confirm",
      title: "Delete?",
      children: [%{type: :button, id: "yes", attrs: %{label: "Yes"}}]
    }

    [summary] = StructuredScreenshot.from_view_tree(tree)

    assert summary.role == :dialog
    assert summary.label == "Delete?"
    assert [%{role: :button, label: "Yes"}] = summary.children
  end

  test "the whole tree serializes to JSON with a11y fields" do
    tree = %{type: :checkbox, id: "agree", label: "Agree", checked: true}

    json =
      tree
      |> StructuredScreenshot.from_view_tree()
      |> StructuredScreenshot.to_json()

    assert json =~ "checkbox"
    assert json =~ "checked?"
  end
end
