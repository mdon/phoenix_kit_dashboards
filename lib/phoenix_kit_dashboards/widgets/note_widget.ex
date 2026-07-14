defmodule PhoenixKitDashboards.Widgets.NoteWidget do
  @moduledoc """
  Built-in "Note" widget — a title + free-text body from its settings, with the
  body rendered as **Markdown** (GFM, XSS-sanitized via core's `<.markdown>`),
  so links, lists and emphasis actually work in a pinned note.

  Otherwise the simplest possible widget: pure presentation, no data loading.
  Use it as the reference shape for a custom widget `Phoenix.LiveComponent`.

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

  import PhoenixKitWeb.Components.Core.Markdown, only: [markdown: 1]

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
    <%!-- Notes are freeform prose: fixed readable type that CLIPS when the box
    is too small (grow the widget or shorten the note — never a scrollbar,
    never silently switched density). --%>
    <div class="card bg-base-100 h-full overflow-hidden">
      <div class="card-body gap-1 overflow-hidden p-3">
        <h3 class="card-title text-sm">{@title}</h3>
        <p :if={@body == ""} class="text-sm text-base-content/70">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Empty note — open settings to add text.")}
        </p>
        <.markdown :if={@body != ""} content={@body} compact class="text-sm text-base-content/80" />
      </div>
    </div>
    """
  end
end
