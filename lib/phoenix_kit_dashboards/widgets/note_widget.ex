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
     |> assign(:body, Map.get(settings, "body", ""))
     # A single-row instance renders dense (tighter padding, smaller text) so a
     # short note FITS the minimum box instead of growing a scrollbar; a long
     # body still scrolls via the host chrome at any size.
     |> assign(:compact, compact?(assigns[:size]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full">
      <div class={["card-body", if(@compact, do: "gap-1 p-2", else: "p-4")]}>
        <h3 class={["card-title", if(@compact, do: "text-xs", else: "text-sm")]}>{@title}</h3>
        <p :if={@body == ""} class={[
          "text-base-content/70",
          if(@compact, do: "text-xs", else: "text-sm")
        ]}>
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Empty note — open settings to add text.")}
        </p>
        <.markdown
          :if={@body != ""}
          content={@body}
          compact
          class={"text-base-content/80 " <> if(@compact, do: "text-xs", else: "text-sm")}
        />
      </div>
    </div>
    """
  end

  defp compact?(%{h: h}) when is_integer(h), do: h < 2
  defp compact?(_), do: false
end
