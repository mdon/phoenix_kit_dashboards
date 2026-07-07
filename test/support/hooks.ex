defmodule PhoenixKitDashboards.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production mounts get `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  from core's `live_session :phoenix_kit_admin`, which the test router doesn't run.
  Tests set a scope via `LiveCase.put_test_scope/2`; the `:assign_scope` hook below
  reads it back and mirrors it onto socket assigns.

  Unlike the minimal reference hook, the `nil` branch still assigns
  `:phoenix_kit_current_scope` (as `nil`) because `BuilderLive.render/1` reads it
  strictly (`scope={@phoenix_kit_current_scope}`) — leaving it absent would raise a
  `KeyError` for any builder test that doesn't set a scope.
  """
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_scope, _params, session, socket) do
    case Map.get(session, "phoenix_kit_test_scope") do
      %{user: user} = scope ->
        {:cont,
         socket
         |> assign(:phoenix_kit_current_scope, scope)
         |> assign(:phoenix_kit_current_user, user)}

      _ ->
        {:cont,
         socket
         |> assign(:phoenix_kit_current_scope, nil)
         |> assign(:phoenix_kit_current_user, nil)}
    end
  end
end
