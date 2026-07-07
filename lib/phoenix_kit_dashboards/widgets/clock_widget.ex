defmodule PhoenixKitDashboards.Widgets.ClockWidget do
  @moduledoc """
  Built-in "Clock" widget — shows the current server time, ticking live.

  Its catalog entry declares `refresh_interval: 1000`, so the host's refresh loop
  `send_update/2`s it every second and `update/2` re-reads `DateTime.utc_now/0`.
  A widget that needs no live data simply omits `refresh_interval`.
  """
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(
       :label,
       Map.get(settings, "label") || Gettext.gettext(PhoenixKitWeb.Gettext, "Server time")
     )
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class="card-body p-4 items-center justify-center text-center">
        <span class="text-xs uppercase tracking-wide text-base-content/50">{@label}</span>
        <span class="text-2xl font-mono">{Calendar.strftime(@now, "%H:%M:%S")}</span>
        <span class="text-xs text-base-content/50">{Calendar.strftime(@now, "%Y-%m-%d UTC")}</span>
      </div>
    </div>
    """
  end
end
