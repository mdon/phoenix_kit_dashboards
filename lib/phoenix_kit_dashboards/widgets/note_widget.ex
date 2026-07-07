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
        view={selected_view}          # nil or a declared view key
        size={%{w: w, h: h}}          # the instance's current span
        scope={@phoenix_kit_current_scope}
      />

  So a widget component handles the `:settings`, `:view`, `:size`, and `:scope`
  assigns (all optional to read). It runs inside the host LiveView's process
  (LiveComponents have no process of their own), so for live data a widget's
  catalog entry declares a `refresh_interval` (ms) and the host re-`send_update/2`s
  it on that cadence — the widget never subscribes/times itself.
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
          {if @body == "",
            do: Gettext.gettext(PhoenixKitWeb.Gettext, "Empty note — open settings to add text."),
            else: @body}
        </p>
      </div>
    </div>
    """
  end
end
