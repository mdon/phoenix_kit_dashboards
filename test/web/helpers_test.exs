defmodule PhoenixKitDashboards.Web.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDashboards.Web.Helpers

  # The consolidated manage rule (review #10) — was three functions under three
  # names across the LVs; now one, tested directly.
  describe "manageable_by?/2" do
    test "own personal dashboard is manageable" do
      assert Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, "u1")
    end

    test "someone else's personal dashboard is not" do
      refute Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, "u2")
      refute Helpers.manageable_by?(%{scope: "personal", owner_user_uuid: "u1"}, nil)
    end

    test "shared/system and role dashboards are manageable by any admin on the page" do
      assert Helpers.manageable_by?(%{scope: "system", owner_user_uuid: nil}, "anyone")
      assert Helpers.manageable_by?(%{scope: "role", owner_user_uuid: nil}, nil)
    end
  end

  describe "scope_label/1" do
    test "translates the known scopes and passes others through" do
      assert Helpers.scope_label("personal") == "personal"
      assert Helpers.scope_label("system") == "shared"
      assert Helpers.scope_label("role") == "role"
      assert Helpers.scope_label("weird") == "weird"
    end
  end

  describe "translate_catalog/1" do
    test "nil passes through; a string round-trips (no translation configured)" do
      assert Helpers.translate_catalog(nil) == nil
      assert Helpers.translate_catalog("Deliverability") == "Deliverability"
    end
  end
end
