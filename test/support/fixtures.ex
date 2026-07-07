defmodule PhoenixKitDashboards.Fixtures do
  @moduledoc """
  Shared test fixtures. Imported by `DataCase` and `LiveCase`.

  `user_fixture/1` inserts a real `phoenix_kit_users` row — required because a
  personal dashboard's `owner_user_uuid` has a foreign key to that table
  (core V133, `ON DELETE CASCADE`), so a made-up UUID would violate the FK.
  """

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitDashboards.Test.Repo, as: TestRepo

  @doc """
  Inserts a confirmed user via core's registration changeset and returns it.

  ## Options
    * `:email` — defaults to a unique-suffix address
    * `:password` — defaults to a valid strong password
  """
  def user_fixture(opts \\ []) do
    email = Keyword.get(opts, :email, "user-#{System.unique_integer([:positive])}@example.com")
    password = Keyword.get(opts, :password, "ValidPassword123!")

    %User{}
    |> User.registration_changeset(%{email: email, password: password})
    |> TestRepo.insert!()
  end
end
