defmodule PhoenixKitDashboards.Widgets.NoteWidget do
  @moduledoc """
  Built-in "Note" widget — renders a title + free-text body from its settings.

  The simplest possible widget: pure presentation, no data loading. Use it as the
  reference shape for a custom widget `Phoenix.LiveComponent`.

  ## Widget LiveComponent contract

  The dashboard host renders every widget as:

      <.live_component
        module={widget.component}
        id={instance_id}
        settings={instance_settings}
        scope={@phoenix_kit_current_scope}
      />

  So a widget component must handle the `:settings` and `:scope` assigns. It runs
  inside the host LiveView's process (LiveComponents have no process of their
  own), so for live updates a widget declares a PubSub topic and the host routes
  messages to it via `send_update/2` — never subscribe from inside `update/2`.
  """
  use Phoenix.LiveComponent

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:title, Map.get(settings, "title", "Note"))
     |> assign(:body, Map.get(settings, "body", ""))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class="card-body p-4">
        <h3 class="card-title text-sm">{@title}</h3>
        <p class="text-sm text-base-content/70 whitespace-pre-wrap">
          {if @body == "", do: "Empty note — open settings to add text.", else: @body}
        </p>
      </div>
    </div>
    """
  end
end
