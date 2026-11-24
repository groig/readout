defmodule ReadoutWeb.ViewerComponents do
  @moduledoc """
  The document viewer: a vertical stack of page images with a thumbnail rail,
  page indicator, keyboard navigation (J/K, ←/→, Home/End) and fullscreen.

  Used by the internal document page and the public viewer. Page boxes take
  their aspect ratio from the PDF page size, so nothing shifts while images
  load. The colocated `.Viewer` hook works out which page is in view; with
  `track`, it also reports it to the LiveView (`"page"` events) and pauses when
  the tab is hidden (`"visibility"` events).
  """
  use ReadoutWeb, :html

  alias Phoenix.LiveView.ColocatedHook

  @doc """
  Renders the viewer. `pages` and `thumbs` are streams of `%Page{}`; `src` and
  `thumb_src` turn a page into an image URL.
  """
  attr :id, :string, required: true
  attr :pages, :any, required: true, doc: "stream of pages for the main stack"
  attr :thumbs, :any, required: true, doc: "stream of pages for the rail"
  attr :page_count, :integer, required: true
  attr :src, :any, required: true
  attr :thumb_src, :any, required: true
  attr :track, :boolean, default: false
  attr :watermark, :string, default: nil, doc: "text tiled over every page (a deterrent only)"
  attr :class, :any, default: nil

  def viewer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".Viewer"
      data-track={@track && "true"}
      data-page-count={@page_count}
      class={[
        "relative flex gap-6 [&:fullscreen]:overflow-y-auto [&:fullscreen]:bg-canvas [&:fullscreen]:p-6",
        @class
      ]}
    >
      <nav
        id={"#{@id}-rail"}
        phx-update="stream"
        aria-label={gettext("Pages")}
        class="sticky top-[calc(var(--topbar-height)+1.5rem)] hidden max-h-[calc(100dvh-var(--topbar-height)-3rem)] w-24 shrink-0 space-y-3 self-start overflow-y-auto pr-1 pb-4 lg:block"
      >
        <a
          :for={{dom_id, page} <- @thumbs}
          id={dom_id}
          href={"##{@id}-page-#{page.number}"}
          data-viewer-thumb={page.number}
          class="group block rounded-md p-1 transition-colors hover:bg-hover data-current:bg-active"
        >
          <span
            class="ui-skeleton block overflow-hidden rounded-sm shadow-xs ring-1 ring-border transition-shadow group-data-current:ring-2 group-data-current:ring-accent"
            style={"aspect-ratio: #{page.width} / #{page.height}"}
          >
            <img
              src={@thumb_src.(page)}
              alt=""
              loading="lazy"
              decoding="async"
              class="h-full w-full"
            />
          </span>
          <span class="mt-1 block text-center text-2xs text-fg-subtle tabular-nums group-data-current:font-medium group-data-current:text-fg">
            {page.number}
          </span>
        </a>
      </nav>

      <div
        id={"#{@id}-pages"}
        phx-update="stream"
        class="mx-auto min-w-0 max-w-3xl flex-1 space-y-4 pb-24"
      >
        <section
          :for={{dom_id, page} <- @pages}
          id={dom_id}
          data-viewer-page={page.number}
          aria-label={gettext("Page %{number}", number: page.number)}
          class="ui-skeleton relative scroll-mt-[calc(var(--topbar-height)+1rem)] overflow-hidden rounded-md bg-white shadow-md ring-1 ring-border"
          style={"aspect-ratio: #{page.width} / #{page.height}"}
        >
          <img
            src={@src.(page)}
            alt={gettext("Page %{number}", number: page.number)}
            loading={if(page.number <= 2, do: "eager", else: "lazy")}
            decoding="async"
            draggable="false"
            class="h-full w-full select-none"
          />
          <div
            :if={@watermark}
            aria-hidden="true"
            class="pointer-events-none absolute inset-0 flex flex-wrap content-around justify-around gap-y-16 overflow-hidden p-6 select-none"
          >
            <span
              :for={_ <- 1..12}
              class="-rotate-30 text-sm font-medium whitespace-nowrap text-black/[0.09]"
            >
              {@watermark}
            </span>
          </div>
        </section>
      </div>

      <div
        id={"#{@id}-controls"}
        phx-update="ignore"
        class="fixed bottom-5 left-1/2 z-30 flex -translate-x-1/2 items-center gap-1 rounded-full border border-border bg-raised/95 p-1 text-sm shadow-lg backdrop-blur md:left-[calc(50%+var(--sidebar-width)/2)] sidebar-collapsed:md:left-[calc(50%+var(--sidebar-rail)/2)] [[data-viewer-standalone]_&]:md:left-1/2"
      >
        <button
          type="button"
          data-viewer-prev
          class="flex size-8 cursor-pointer items-center justify-center rounded-full text-fg-muted transition-colors hover:bg-hover hover:text-fg active:scale-90"
          aria-label={gettext("Previous page")}
        >
          <.icon name="hero-chevron-up-mini" class="size-4" />
        </button>
        <span class="min-w-16 px-1 text-center text-fg tabular-nums" aria-live="polite">
          <span data-viewer-current>1</span>
          <span class="text-fg-subtle">/ {@page_count}</span>
        </span>
        <button
          type="button"
          data-viewer-next
          class="flex size-8 cursor-pointer items-center justify-center rounded-full text-fg-muted transition-colors hover:bg-hover hover:text-fg active:scale-90"
          aria-label={gettext("Next page")}
        >
          <.icon name="hero-chevron-down-mini" class="size-4" />
        </button>
        <span class="mx-0.5 h-5 w-px bg-border" />
        <button
          type="button"
          data-viewer-fullscreen
          class="flex size-8 cursor-pointer items-center justify-center rounded-full text-fg-muted transition-colors hover:bg-hover hover:text-fg active:scale-90"
          aria-label={gettext("Fullscreen")}
        >
          <.icon name="hero-arrows-pointing-out-mini" class="size-4" />
        </button>
      </div>
    </div>
    <script :type={ColocatedHook} name=".Viewer">
      // Which page is in view (the most visible one), page navigation and
      // fullscreen. With data-track, reports the page and tab visibility to
      // the server, which measures time; the client only says which page.
      export default {
        mounted() {
          this.current = 0
          this.ratios = new Map()
          this.track = this.el.dataset.track === "true"
          this.io = new IntersectionObserver(entries => {
            for (const e of entries) this.ratios.set(Number(e.target.dataset.viewerPage), e.intersectionRatio)
            let best = 0, bestRatio = 0
            this.ratios.forEach((r, n) => { if (r > bestRatio || (r === bestRatio && n < best)) { best = n; bestRatio = r } })
            if (best && bestRatio > 0 && best !== this.current) this.setCurrent(best)
          }, {threshold: [0, 0.1, 0.25, 0.5, 0.75, 1]})
          this.observe()

          const q = s => this.el.querySelector(s)
          q("[data-viewer-prev]").addEventListener("click", () => this.goTo((this.target || this.current) - 1))
          q("[data-viewer-next]").addEventListener("click", () => this.goTo((this.target || this.current) + 1))
          q("[data-viewer-fullscreen]").addEventListener("click", () => this.toggleFullscreen())

          this.onKey = e => {
            if (e.metaKey || e.ctrlKey || e.altKey) return
            if (e.target.closest?.("input, textarea, select, [contenteditable]")) return
            if (document.querySelector("dialog[open]")) return
            const keys = {j: 1, ArrowRight: 1, PageDown: 1, k: -1, ArrowLeft: -1, PageUp: -1}
            // Base repeated presses on where we're heading, not where the
            // smooth scroll currently is.
            if (keys[e.key]) { e.preventDefault(); this.goTo((this.target || this.current) + keys[e.key]) }
            else if (e.key === "Home") { e.preventDefault(); this.goTo(1) }
            else if (e.key === "End") { e.preventDefault(); this.goTo(this.count()) }
            else if (e.key === "f") { e.preventDefault(); this.toggleFullscreen() }
          }
          window.addEventListener("keydown", this.onKey)

          if (this.track) {
            this.onVisibility = () => this.pushEvent("visibility", {visible: document.visibilityState === "visible"})
            document.addEventListener("visibilitychange", this.onVisibility)
          }
        },
        updated() { this.observe() },
        observe() {
          this.el.querySelectorAll("[data-viewer-page]").forEach(p => {
            if (!p.dataset.observed) { p.dataset.observed = "1"; this.io.observe(p) }
          })
        },
        count() { return Number(this.el.dataset.pageCount) || 1 },
        setCurrent(n) {
          this.current = n
          this.el.querySelector("[data-viewer-current]").textContent = n
          this.el.querySelectorAll("[data-viewer-thumb]").forEach(t => {
            const on = Number(t.dataset.viewerThumb) === n
            t.toggleAttribute("data-current", on)
            if (on) t.scrollIntoView({block: "nearest"})
          })
          if (this.track) this.pushEvent("page", {page: n})
        },
        goTo(n) {
          n = Math.max(1, Math.min(this.count(), n))
          this.target = n
          clearTimeout(this.targetTimer)
          this.targetTimer = setTimeout(() => this.target = null, 700)
          const page = this.el.querySelector(`[data-viewer-page="${n}"]`)
          const smooth = !matchMedia("(prefers-reduced-motion: reduce)").matches
          page?.scrollIntoView({behavior: smooth ? "smooth" : "auto", block: "start"})
        },
        toggleFullscreen() {
          if (document.fullscreenElement) document.exitFullscreen()
          else this.el.requestFullscreen?.()
        },
        destroyed() {
          this.io.disconnect()
          window.removeEventListener("keydown", this.onKey)
          clearTimeout(this.targetTimer)
          if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
        }
      }
    </script>
    """
  end
end
