defmodule Raxol.Core.Accessibility.RolesTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Accessibility.Roles

  describe "role_for/1" do
    test "maps interactive Component types to ARIA roles" do
      assert Roles.role_for(:button) == :button
      assert Roles.role_for(:text_input) == :textbox
      assert Roles.role_for(:text_area) == :textbox
      assert Roles.role_for(:password_field) == :textbox
      assert Roles.role_for(:checkbox) == :checkbox
      assert Roles.role_for(:select_list) == :listbox
      assert Roles.role_for(:menu) == :menu
      assert Roles.role_for(:tabs) == :tablist
      assert Roles.role_for(:modal) == :dialog
    end

    test "maps Table to :grid (interactive-grid variant)" do
      assert Roles.role_for(:table) == :grid
    end

    test "maps structural + chart types" do
      assert Roles.role_for(:tree) == :tree
      assert Roles.role_for(:viewport) == :region
      assert Roles.role_for(:progress) == :progressbar
      assert Roles.role_for(:bar_chart) == :img
      assert Roles.role_for(:line_chart) == :img
      assert Roles.role_for(:scatter_chart) == :img
    end

    test "maps layout primitives to :group and text to :text" do
      assert Roles.role_for(:row) == :group
      assert Roles.role_for(:column) == :group
      assert Roles.role_for(:box) == :group
      assert Roles.role_for(:text) == :text
      assert Roles.role_for(:label) == :text
    end

    test "unknown or non-atom types fall back to :generic" do
      assert Roles.role_for(:frobnicate) == :generic
      assert Roles.role_for("button") == :generic
      assert Roles.role_for(nil) == :generic
      assert Roles.role_for(42) == :generic
    end
  end

  describe "live?/1" do
    test "true for live-region roles" do
      assert Roles.live?(:alert)
      assert Roles.live?(:status)
      assert Roles.live?(:log)
      assert Roles.live?(:progressbar)
    end

    test "false otherwise" do
      refute Roles.live?(:button)
      refute Roles.live?(:grid)
      refute Roles.live?(:generic)
    end
  end

  describe "child_role/1" do
    test "returns the conventional child role for a container" do
      assert Roles.child_role(:listbox) == :option
      assert Roles.child_role(:menu) == :menuitem
      assert Roles.child_role(:tablist) == :tab
      assert Roles.child_role(:tree) == :treeitem
    end

    test "nil when no convention" do
      assert Roles.child_role(:button) == nil
      assert Roles.child_role(nil) == nil
    end
  end

  test "default_role/0" do
    assert Roles.default_role() == :generic
  end
end
