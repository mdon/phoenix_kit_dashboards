defmodule PhoenixKitDashboards.Widgets.ClockWidget do
  @moduledoc """
  Built-in "Clock" widget — the current time, ticking live, in one of three
  views, with a per-instance timezone.

  This is the worked example for the richer parts of the widget contract:

    * **Views with per-view minimums** — `"normal"` (time + date), `"digital"`
      (large LCD-style digits) and `"analog"` (an SVG face) each declare their
      own `min_size`: the analog face needs a squarer box (2×2) than a line of
      digits (3×1). Resize limits, the settings modal, and view switching all
      honour the selected view's floor.
    * **Per-instance settings** — every placed clock has its own `"timezone"`
      and a `"show_timezone"` toggle (hide the label when a single local clock
      doesn't need it), so one dashboard can carry a world-clock row.
    * **Live refresh** — the catalog entry declares `refresh_interval: 1000`;
      the host `send_update/2`s the component every second and `update/2`
      re-reads the time.

  ## Timezones

  `"UTC"` and fixed offsets (`"UTC+2"`, `"UTC-7"`, …) always work — the offset
  is plain arithmetic, no timezone database needed. IANA city zones
  (`"Europe/Tallinn"`, …) are offered only when the HOST app configured a real
  time zone database (e.g. `tzdata` + `config :elixir, :time_zone_database`);
  a stored city zone that can't be resolved degrades to UTC rather than
  crashing the dashboard.
  """
  use Phoenix.LiveComponent

  # Offered only when the host has a real time zone database configured.
  @iana_zones ~w(
    America/Los_Angeles America/Denver America/Chicago America/New_York
    America/Sao_Paulo Europe/London Europe/Berlin Europe/Tallinn Europe/Moscow
    Asia/Dubai Asia/Kolkata Asia/Shanghai Asia/Tokyo Australia/Sydney
    Pacific/Auckland
  )

  @offset_re ~r/^UTC(?<sign>[+-])(?<h>\d{1,2})(?::(?<m>\d{2}))?$/

  @doc """
  The timezone choices for the settings select: UTC, IANA city zones when the
  host has a timezone database (checked live, so adding `tzdata` to the host
  lights them up after a registry refresh), and fixed UTC offsets — which are
  always correct by construction (they claim an offset, not a place).
  """
  @spec timezone_options() :: [String.t()]
  def timezone_options do
    iana = if iana_available?(), do: @iana_zones, else: []
    ["UTC"] ++ iana ++ offset_options()
  end

  @doc """
  Resolve a timezone setting to `{now, zone_label}` — the shifted time plus the
  label to show. Fixed offsets are pure arithmetic; IANA zones go through
  `DateTime.shift_zone/2` and degrade to UTC when no database can resolve them.
  """
  @spec resolve_time(term()) :: {DateTime.t(), String.t()}
  def resolve_time("UTC"), do: {DateTime.utc_now(), "UTC"}

  def resolve_time(tz) when is_binary(tz) do
    case Regex.named_captures(@offset_re, tz) do
      %{"sign" => sign, "h" => h, "m" => m} ->
        offset_time(tz, sign, String.to_integer(h), String.to_integer(blank_zero(m)))

      nil ->
        case DateTime.shift_zone(DateTime.utc_now(), tz) do
          {:ok, shifted} -> {shifted, shifted.zone_abbr}
          {:error, _} -> {DateTime.utc_now(), "UTC"}
        end
    end
  end

  # Real-world offsets only (UTC-12:00 … UTC+14:00, total) — a crafted or
  # stale setting like "UTC+99:99" or the boundary-overshooting "UTC+14:59"
  # degrades to UTC instead of rendering a time shifted past any real zone.
  defp offset_time(tz, sign, hours, minutes) when minutes in 0..59 do
    total = hours * 60 + minutes

    if (sign == "+" and total <= 14 * 60) or (sign == "-" and total <= 12 * 60) do
      secs = if(sign == "-", do: -1, else: 1) * total * 60
      {DateTime.add(DateTime.utc_now(), secs, :second), tz}
    else
      {DateTime.utc_now(), "UTC"}
    end
  end

  defp offset_time(_tz, _sign, _hours, _minutes), do: {DateTime.utc_now(), "UTC"}

  def resolve_time(_), do: {DateTime.utc_now(), "UTC"}

  @impl true
  def update(assigns, socket) do
    settings = assigns[:settings] || %{}
    {now, zone} = resolve_time(Map.get(settings, "timezone", "UTC"))
    {digits, suffix} = format_time(now, Map.get(settings, "format", "24h"))

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:label, to_string(Map.get(settings, "label") || ""))
     |> assign(:show_tz, Map.get(settings, "show_timezone", true) in [true, "true"])
     |> assign(:view, assigns[:view] || "normal")
     |> assign(:zone, zone)
     |> assign(:now, now)
     |> assign(:digits, digits)
     |> assign(:suffix, suffix)
     # A single-row instance gets the compact treatment: smaller digits, no
     # date line, tighter padding — the clock must always FIT its box (the root
     # clips as the last resort; a clock with a scrollbar is broken).
     |> assign(:compact, compact?(assigns[:size]))}
  end

  # The time as {digits, suffix}: 24h has no suffix; 12h renders "hh:mm:ss"
  # with a small AM/PM suffix (the analog face ignores the format — a dial is
  # 12-hour by nature).
  defp format_time(now, "12h"),
    do: {Calendar.strftime(now, "%I:%M:%S"), Calendar.strftime(now, "%p")}

  defp format_time(now, _), do: {Calendar.strftime(now, "%H:%M:%S"), nil}

  defp compact?(%{h: h}) when is_integer(h), do: h < 2
  defp compact?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 h-full overflow-hidden">
      <div class={[
        "card-body flex h-full min-h-0 flex-col items-center justify-center text-center",
        if(@compact, do: "gap-0.5 p-2", else: "gap-1 p-3")
      ]}>
        <span :if={@label != ""} class="text-xs uppercase tracking-wide text-base-content/50">
          {@label}
        </span>

        <.analog_face :if={@view == "analog"} now={@now} />

        <span
          :if={@view == "digital"}
          class={[
            "rounded-lg bg-base-200 font-mono font-semibold tabular-nums tracking-wider",
            if(@compact, do: "px-3 py-0.5 text-2xl", else: "px-4 py-2 text-4xl")
          ]}
        >
          {@digits}<span :if={@suffix} class="ml-1 align-baseline text-sm font-normal">{@suffix}</span>
        </span>

        <%= if @view not in ["analog", "digital"] do %>
          <span class="font-mono text-2xl tabular-nums">
            {@digits}<span :if={@suffix} class="ml-1 text-sm font-normal text-base-content/60">{@suffix}</span>
          </span>
          <span :if={not @compact} class="text-xs text-base-content/50">
            {Calendar.strftime(@now, "%Y-%m-%d")}
          </span>
        <% end %>

        <span :if={@show_tz} class="text-xs text-base-content/50">{@zone}</span>
      </div>
    </div>
    """
  end

  # The SVG face fills whatever box the instance has, letterboxed square by the
  # viewBox — so "analog wants a square" is a soft preference the per-view
  # min_size nudges toward, not a hard aspect lock the grid can't express
  # (cells aren't square: column and row strides differ per tier).
  attr(:now, DateTime, required: true)

  defp analog_face(assigns) do
    assigns =
      assign(assigns,
        h_deg: rem(assigns.now.hour, 12) * 30 + assigns.now.minute * 0.5,
        m_deg: assigns.now.minute * 6 + assigns.now.second * 0.1,
        s_deg: assigns.now.second * 6,
        ticks:
          for i <- 0..11 do
            angle = i * :math.pi() / 6

            {50 + 41 * :math.sin(angle), 50 - 41 * :math.cos(angle), 50 + 46 * :math.sin(angle),
             50 - 46 * :math.cos(angle)}
          end
      )

    ~H"""
    <div class="flex min-h-0 w-full flex-1 items-center justify-center">
      <svg viewBox="0 0 100 100" class="block h-full max-h-full max-w-full" aria-hidden="true">
        <circle
          cx="50"
          cy="50"
          r="48"
          class="fill-base-200/60 stroke-base-content/15"
          stroke-width="2"
        />
        <line
          :for={{x1, y1, x2, y2} <- @ticks}
          x1={x1}
          y1={y1}
          x2={x2}
          y2={y2}
          class="stroke-base-content/40"
          stroke-width="2"
          stroke-linecap="round"
        />
        <line
          x1="50"
          y1="50"
          x2="50"
          y2="28"
          class="stroke-base-content"
          stroke-width="4"
          stroke-linecap="round"
          transform={"rotate(#{@h_deg} 50 50)"}
        />
        <line
          x1="50"
          y1="50"
          x2="50"
          y2="19"
          class="stroke-base-content/80"
          stroke-width="2.5"
          stroke-linecap="round"
          transform={"rotate(#{@m_deg} 50 50)"}
        />
        <line
          x1="50"
          y1="55"
          x2="50"
          y2="16"
          class="stroke-error"
          stroke-width="1.2"
          stroke-linecap="round"
          transform={"rotate(#{@s_deg} 50 50)"}
        />
        <circle cx="50" cy="50" r="2.5" class="fill-base-content" />
      </svg>
    </div>
    """
  end

  defp iana_available? do
    match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), "Europe/London"))
  end

  # UTC-12 … UTC+14, whole hours (the parser also accepts :mm halves, so a
  # stored "UTC+5:30" keeps working even though the picker offers whole hours).
  defp offset_options do
    for h <- -12..14, h != 0 do
      if h > 0, do: "UTC+#{h}", else: "UTC#{h}"
    end
  end

  defp blank_zero(""), do: "0"
  defp blank_zero(m), do: m
end
