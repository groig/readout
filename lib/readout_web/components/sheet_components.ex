defmodule ReadoutWeb.SheetComponents do
  @moduledoc """
  The spreadsheet viewer: sheet tabs, a table (sticky header and first
  column, paged rows, numbers right-aligned) and a chart of a numeric column.
  State lives in `ReadoutWeb.SheetView`; events are `sheet:*`.

  With `track`, a tiny hook reports tab visibility and activity (the server
  knows which sheet is open and measures the time).
  """
  use ReadoutWeb, :html

  alias Phoenix.LiveView.ColocatedHook
  alias ReadoutWeb.SheetView

  attr :id, :string, required: true
  attr :sheet, :map, required: true
  attr :rows, :any, required: true, doc: "the :sheet_rows stream"
  attr :track, :boolean, default: false
  attr :watermark, :string, default: nil

  def sheet_viewer(assigns) do
    assigns =
      assign(
        assigns,
        :bars,
        if(assigns.sheet.mode == :chart, do: SheetView.chart_bars(assigns.sheet), else: [])
      )

    ~H"""
    <div id={@id} phx-hook={@track && "ReadoutWeb.SheetComponents.Activity"} class="mx-auto max-w-6xl">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <nav
          :if={length(@sheet.names) > 1}
          class="flex flex-wrap gap-1"
          aria-label={gettext("Sheets")}
        >
          <button
            :for={{name, i} <- Enum.with_index(@sheet.names, 1)}
            id={"#{@id}-tab-#{i}"}
            type="button"
            phx-click="sheet:select"
            phx-value-index={i}
            aria-pressed={to_string(i == @sheet.index)}
            class={[
              "h-8 cursor-pointer rounded-md px-3 text-sm transition-colors",
              if(i == @sheet.index,
                do: "bg-active font-medium text-fg",
                else: "text-fg-muted hover:bg-hover hover:text-fg"
              )
            ]}
          >
            {name}
          </button>
        </nav>
        <div class="ml-auto flex items-center gap-2">
          <.segmented :if={@sheet.numeric_columns != []} id={"#{@id}-mode"}>
            <:item
              phx-click="sheet:mode"
              phx-value-mode="table"
              active={@sheet.mode == :table}
              icon="hero-table-cells-mini"
              label={gettext("Table")}
            />
            <:item
              phx-click="sheet:mode"
              phx-value-mode="chart"
              active={@sheet.mode == :chart}
              icon="hero-chart-bar-mini"
              label={gettext("Chart")}
            />
          </.segmented>
        </div>
      </div>

      <%= if @sheet.mode == :chart do %>
        <div id={"#{@id}-chart"} class="rounded-xl border border-border bg-surface p-4 shadow-xs">
          <form id={"#{@id}-column-form"} phx-change="sheet:column" class="mb-4 max-w-xs">
            <.input
              type="select"
              name="column"
              id={"#{@id}-column"}
              value={@sheet.column}
              label={gettext("Column")}
              options={
                for i <- @sheet.numeric_columns,
                    do: {Enum.at(@sheet.header, i) || gettext("Column %{n}", n: i + 1), i}
              }
            />
          </form>
          <.bar_chart :if={@bars != []} id={"#{@id}-bars"} bars={@bars} height="16rem" />
          <p class="mt-2 text-xs text-fg-subtle">
            {gettext("First %{n} rows.", n: SheetView.chart_rows())}
          </p>
        </div>
      <% else %>
        <div
          class="relative overflow-auto rounded-xl border border-border bg-surface shadow-xs"
          style="max-height: calc(100dvh - 12rem)"
        >
          <table class="w-full border-separate border-spacing-0 text-sm">
            <thead>
              <tr>
                <th class="sticky top-0 left-0 z-20 w-12 border-b border-border bg-inset px-2 py-2 text-right text-2xs font-medium text-fg-faint">
                  #
                </th>
                <th
                  :for={{h, i} <- Enum.with_index(@sheet.header)}
                  class={[
                    "sticky top-0 z-10 border-b border-border bg-inset px-3 py-2 text-left text-xs font-medium whitespace-nowrap text-fg-muted",
                    Enum.at(@sheet.numeric, i) && "text-right"
                  ]}
                >
                  {h}
                </th>
              </tr>
            </thead>
            <tbody id={"#{@id}-rows"} phx-update="stream">
              <tr :for={{dom_id, {n, row}} <- @rows} id={dom_id} class="group">
                <td class="sticky left-0 border-b border-border bg-surface px-2 py-1.5 text-right text-2xs text-fg-faint tabular-nums group-hover:bg-hover">
                  {n}
                </td>
                <td
                  :for={{cell, i} <- Enum.with_index(row)}
                  class={[
                    "max-w-80 truncate border-b border-border px-3 py-1.5 text-fg group-hover:bg-hover/60",
                    Enum.at(@sheet.numeric, i) && "text-right tabular-nums"
                  ]}
                  title={String.length(cell) > 40 && cell}
                >
                  {cell}
                </td>
              </tr>
            </tbody>
          </table>
          <div
            :if={@watermark}
            aria-hidden="true"
            class="pointer-events-none absolute inset-0 flex flex-wrap content-around justify-around gap-y-24 overflow-hidden p-6 select-none"
          >
            <span
              :for={_ <- 1..12}
              class="-rotate-30 text-sm font-medium whitespace-nowrap text-fg/[0.07]"
            >{@watermark}</span>
          </div>
        </div>
        <div class="mt-3 flex items-center justify-between text-xs text-fg-subtle">
          <span class="tabular-nums">
            {ngettext("%{count} row", "%{count} rows", @sheet.row_count)}
            <span :if={@sheet.truncated}>· {gettext("showing the first rows only")}</span>
          </span>
          <span :if={@sheet.pages > 1} class="flex items-center gap-1">
            <.icon_button
              icon="hero-chevron-left-mini"
              label={gettext("Previous rows")}
              size="xs"
              phx-click="sheet:page"
              phx-value-page={@sheet.page - 1}
              disabled={@sheet.page == 1}
            />
            <span class="tabular-nums">{@sheet.page} / {@sheet.pages}</span>
            <.icon_button
              icon="hero-chevron-right-mini"
              label={gettext("Next rows")}
              size="xs"
              phx-click="sheet:page"
              phx-value-page={@sheet.page + 1}
              disabled={@sheet.page == @sheet.pages}
            />
          </span>
        </div>
      <% end %>
    </div>
    <script :type={ColocatedHook} name=".Activity">
      // Tab visibility and "still here" pings for reading time; the server
      // knows which sheet is open.
      export default {
        mounted() {
          this.onVisibility = () => this.pushEvent("visibility", {visible: document.visibilityState === "visible"})
          document.addEventListener("visibilitychange", this.onVisibility)
          this.last = 0
          this.onActivity = () => {
            const t = Date.now()
            if (t - this.last > 15000) { this.last = t; this.pushEvent("activity", {}) }
          }
          for (const ev of ["scroll", "pointermove", "pointerdown", "keydown", "wheel", "touchstart"])
            window.addEventListener(ev, this.onActivity, {passive: true, capture: true})
        },
        destroyed() {
          document.removeEventListener("visibilitychange", this.onVisibility)
          for (const ev of ["scroll", "pointermove", "pointerdown", "keydown", "wheel", "touchstart"])
            window.removeEventListener(ev, this.onActivity, {capture: true})
        }
      }
    </script>
    """
  end
end
