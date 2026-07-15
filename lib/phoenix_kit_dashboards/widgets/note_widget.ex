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
    # Defense in depth: the context filters settings to scalars, but a widget
    # must never let a legacy/hostile stored value crash every later mount.
    body = with b when is_binary(b) <- Map.get(settings, "body", ""), do: b
    body = if is_binary(body), do: body, else: ""

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:title, Map.get(settings, "title", "Note"))
     |> assign(:body, body)
     |> assign(:font_cqmin, fit_font(body, assigns[:size]))}
  end

  # CONTENT-AWARE type: the font size that lets the whole note fit its box,
  # in container-query units so it tracks the rendered size at any fit scale.
  # Glyph-box model: prose at font f consumes ≈ 1.15f² per character once
  # line-height, heading scale and paragraph margins are folded in (tuned
  # against rendered markdown); the box is design px (cells × 25) minus the
  # title row, with a 0.55 usable factor for paddings and ragged line ends.
  defp fit_font(body, size) do
    {w, h} =
      case size do
        %{w: w, h: h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 -> {w, h}
        _ -> {16, 8}
      end

    chars = body |> String.replace(~r/[#*_`~\[\]()>-]/, "") |> String.length() |> max(60)
    lines = body |> String.split("\n", trim: true) |> length() |> max(1)
    body_h = h * 25 - 40
    usable = w * 25 * body_h * 0.55
    # Two bounds: total glyph area, and the LINE count (a list of short lines
    # is line-bound long before it is area-bound). The floor keeps the type
    # legible — a note that can't fit even at the floor clips (grow the box
    # or shorten the note).
    f_area = :math.sqrt(max(usable, 1) / chars / 1.15)
    f_lines = body_h / (lines * 1.6)
    f = min(f_area, f_lines) |> min(20.0) |> max(6.0)

    # 100cqmin = the box's smaller dimension (≈ min(w, h) × 25 design px).
    Float.round(f / (min(w, h) * 25) * 100, 2)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Notes are freeform prose that SELF-FITS: the type size is derived
    from the text length and the box (fit_font/2), in cq units — a short note
    in a big box posters up, a long note in a small box shrinks to fit. Never
    a scrollbar, never a silently switched density. --%>
    <div class="card bg-base-100 h-full overflow-hidden [container-type:size]">
      <div class="card-body flex h-full min-h-0 flex-col gap-1 overflow-hidden p-3">
        <h3 class="card-title text-[8cqmin] leading-tight">{@title}</h3>
        <p :if={@body == ""} class="text-[6cqmin] text-base-content/70">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Empty note — open settings to add text.")}
        </p>
        <%!-- prose children are em-based, so scaling the prose ROOT font
        scales the whole rendered markdown. `.prose` sets its own root size,
        so a scoped inherit-override lets the wrapper's cq size through
        (core's <.markdown> declares no style attr to carry it directly). --%>
        <style>
          .pk-note-fit .prose {
            font-size: inherit !important;
          }
        </style>
        <div
          :if={@body != ""}
          class="pk-note-fit min-h-0 flex-1 overflow-hidden"
          style={"font-size: #{@font_cqmin}cqmin"}
        >
          <.markdown content={@body} compact class="text-base-content/80" />
        </div>
      </div>
    </div>
    """
  end
end
