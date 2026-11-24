defmodule ReadoutWeb.ChartComponents do
  @moduledoc """
  Analytics building blocks in pure SVG and CSS (no chart library): stat
  tiles, sparklines, a column chart and a horizontal bar list.

  Numbers use tabular figures so they don't jitter while updating live.
  """
  use Phoenix.Component
  use Gettext, backend: ReadoutWeb.Gettext

  import ReadoutWeb.CoreComponents, only: [icon: 1]

  @doc """
  A stat tile: label, big number, optional delta and a chart slot.

      <.stat_tile label={gettext("Visits")} value="1,204" delta={12.5}>
        <:chart><.sparkline id="visits-spark" values={@series} /></:chart>
      </.stat_tile>

  `delta` is a percentage change; positive is shown as good unless
  `inverse` is set.
  """
  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :delta, :any, default: nil
  attr :delta_label, :string, default: nil
  attr :inverse, :boolean, default: false
  attr :hint, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :chart

  def stat_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "@container flex flex-col justify-between gap-3 rounded-lg border border-border bg-surface p-4 shadow-xs",
        @class
      ]}
    >
      <div class="flex items-center gap-1.5 text-sm text-fg-muted">
        <.icon :if={@icon} name={@icon} class="size-4 text-fg-subtle" />
        <span class="truncate">{@label}</span>
      </div>
      <div class="flex items-end justify-between gap-3">
        <div class="min-w-0">
          <p class="flex items-baseline gap-1 text-2xl font-semibold text-fg tabular-nums">
            {@value}<span :if={@unit} class="text-sm font-medium text-fg-subtle">{@unit}</span>
          </p>
          <p :if={@delta != nil or @hint} class="mt-1 flex items-center gap-1.5 text-xs">
            <span
              :if={@delta != nil}
              class={[
                "inline-flex items-center gap-0.5 font-medium tabular-nums",
                delta_tone(@delta, @inverse)
              ]}
            >
              <.icon :if={@delta > 0} name="hero-arrow-up-right-micro" class="size-3" />
              <.icon :if={@delta < 0} name="hero-arrow-down-right-micro" class="size-3" />
              {format_delta(@delta)}
            </span>
            <span :if={@delta_label || @hint} class="truncate text-fg-subtle">
              {@delta_label || @hint}
            </span>
          </p>
        </div>
        <div :if={@chart != []} class="hidden w-24 shrink-0 @[14rem]:block">
          {render_slot(@chart)}
        </div>
      </div>
    </div>
    """
  end

  defp delta_tone(delta, inverse) do
    good? = if inverse, do: delta < 0, else: delta > 0

    cond do
      delta == 0 -> "text-fg-subtle"
      good? -> "text-success-fg"
      true -> "text-danger-fg"
    end
  end

  defp format_delta(delta) when is_number(delta) do
    sign = if delta > 0, do: "+", else: ""

    "#{sign}#{:erlang.float_to_binary(delta * 1.0, decimals: if(abs(delta) < 10, do: 1, else: 0))}%"
  end

  @doc """
  A sparkline: a smooth-ish line with a soft area fill and an end dot.

      <.sparkline id="spark" values={[1, 4, 2, 8, 5]} />
  """
  attr :id, :string, required: true
  attr :values, :list, required: true
  attr :width, :integer, default: 120
  attr :height, :integer, default: 32
  attr :tone, :string, default: "accent", values: ~w(accent success danger neutral)
  attr :class, :any, default: "w-full h-8"
  attr :label, :string, default: nil

  def sparkline(assigns) do
    {line, area, last} = sparkline_paths(assigns.values, assigns.width, assigns.height)

    assigns =
      assign(assigns,
        line: line,
        area: area,
        last: last,
        stroke: tone_color(assigns.tone)
      )

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@width} #{@height}"}
      preserveAspectRatio="none"
      class={["overflow-visible", @class]}
      role="img"
      aria-label={@label || gettext("Trend")}
    >
      <defs>
        <linearGradient id={"#{@id}-fill"} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color={@stroke} stop-opacity="0.22" />
          <stop offset="100%" stop-color={@stroke} stop-opacity="0" />
        </linearGradient>
      </defs>
      <path :if={@area} d={@area} fill={"url(##{@id}-fill)"} />
      <path
        :if={@line}
        d={@line}
        fill="none"
        stroke={@stroke}
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
      <circle
        :if={@last}
        cx={elem(@last, 0)}
        cy={elem(@last, 1)}
        r="2"
        fill={@stroke}
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp tone_color("accent"), do: "var(--color-accent)"
  defp tone_color("success"), do: "var(--color-success)"
  defp tone_color("danger"), do: "var(--color-danger)"
  defp tone_color("neutral"), do: "var(--color-fg-subtle)"

  @doc false
  def sparkline_paths(values, _w, _h) when length(values) < 2, do: {nil, nil, nil}

  def sparkline_paths(values, w, h) do
    max = Enum.max(values)
    min = Enum.min(values)
    range = if max == min, do: 1, else: max - min
    pad = 2
    step = w / (length(values) - 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        x = Float.round(i * step, 2)
        y = Float.round(h - pad - (v - min) / range * (h - pad * 2), 2)
        {x, y}
      end)

    [{x0, y0} | rest] = points
    line = Enum.reduce(rest, "M#{x0},#{y0}", fn {x, y}, acc -> acc <> " L#{x},#{y}" end)
    {lx, _} = List.last(points)
    area = line <> " L#{lx},#{h} L#{x0},#{h} Z"
    {line, area, List.last(points)}
  end

  @doc """
  A column chart in CSS: one column per item, scaled to the largest value.
  Hovering a column shows its tooltip. Used for "time per page".

      <.bar_chart id="pages" bars={[%{label: "1", value: 42, display: "42s", hint: "Page 1"}]} />

  Each bar is a map with `:label`, `:value`, and optionally `:display`
  (formatted value), `:hint` (tooltip title) and `:tone`.
  """
  attr :id, :string, required: true
  attr :bars, :list, required: true
  attr :height, :string, default: "10rem"
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def bar_chart(assigns) do
    max = assigns.bars |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)
    count = length(assigns.bars)
    # Show at most ~12 x-axis labels.
    every = max(1, ceil(count / 12))

    assigns = assign(assigns, max: max, every: every)

    ~H"""
    <div id={@id} class={["w-full", @class]} role="img" aria-label={@label}>
      <div class="flex items-end gap-[3px]" style={"height: #{@height}"}>
        <div
          :for={{bar, i} <- Enum.with_index(@bars)}
          class="group relative flex h-full min-w-0 flex-1 flex-col justify-end"
        >
          <div
            class={[
              "w-full rounded-t-[3px] transition-[height,background-color] duration-(--duration-slow) ease-(--ease-out)",
              bar_tone(bar[:tone]),
              "min-h-px group-hover:brightness-110"
            ]}
            style={"height: #{bar_pct(bar.value, @max)}%"}
          />
          <div class="ui-tooltip bottom-full left-1/2 mb-1.5 -translate-x-1/2 rounded-md bg-fg px-2 py-1 text-xs text-canvas shadow-md group-hover:opacity-100 group-hover:[transform:translate(-50%,0)]">
            <span :if={bar[:hint]} class="block font-medium">{bar[:hint]}</span>
            <span class="tabular-nums opacity-80">{bar[:display] || bar.value}</span>
          </div>
          <span class={[
            "absolute top-full mt-1.5 w-full text-center text-2xs text-fg-subtle tabular-nums",
            rem(i, @every) != 0 && "invisible"
          ]}>
            {bar.label}
          </span>
        </div>
      </div>
      <div class="h-6" />
    </div>
    """
  end

  defp bar_pct(_value, 0), do: 0
  defp bar_pct(value, max), do: Float.round(value / max * 100, 2)

  defp bar_tone(nil), do: "bg-accent/80 group-hover:bg-accent"
  defp bar_tone("muted"), do: "bg-fg-faint/60 group-hover:bg-fg-faint"
  defp bar_tone("warning"), do: "bg-warning/80 group-hover:bg-warning"
  defp bar_tone("danger"), do: "bg-danger/80 group-hover:bg-danger"

  @doc """
  A ranked list with proportional bars behind each row (e.g. per-link
  breakdown, top pages).

      <.bar_list id="links" items={[%{label: "Client X", value: 12, display: "12 visits"}]} />
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :class, :any, default: nil

  def bar_list(assigns) do
    max = assigns.items |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, max: max)

    ~H"""
    <ul id={@id} class={["space-y-1", @class]}>
      <li :for={item <- @items} class="relative flex h-8 items-center justify-between gap-3 px-2.5">
        <div
          class="absolute inset-y-0 left-0 rounded-md bg-accent-soft transition-[width] duration-(--duration-slow) ease-(--ease-out)"
          style={"width: #{bar_pct(item.value, @max)}%"}
        />
        <span class="relative truncate text-sm text-fg">{item.label}</span>
        <span class="relative shrink-0 text-sm text-fg-muted tabular-nums">
          {item[:display] || item.value}
        </span>
      </li>
    </ul>
    """
  end
end
