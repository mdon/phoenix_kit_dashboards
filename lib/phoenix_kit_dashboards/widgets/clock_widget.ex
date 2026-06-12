defmodule PhoenixKitDashboards.Widgets.ClockWidget do
  @moduledoc """
  Built-in "Clock" widget — shows the current server time.

  Renders a snapshot taken at render time. To make it tick live, the host
  LiveView would `Process.send_after/3` itself a `:tick` and re-`send_update/2`
  this component — see the PubSub note in `PhoenixKitDashboards.Widgets.NoteWidget`.
  """
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:label, Map.get(settings, "label", "Server time"))
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
