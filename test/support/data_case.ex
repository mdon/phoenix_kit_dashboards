defmodule PhoenixKitDashboards.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses the SQL Sandbox for transaction-based isolation and auto-tags
  `:integration` so DB-less runs skip it.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitDashboards.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitDashboards.ActivityLogAssertions
      import PhoenixKitDashboards.Fixtures
      import PhoenixKitDashboards.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDashboards.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
