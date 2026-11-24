defmodule ReadoutWeb.Layouts do
  @moduledoc """
  Layouts:

    * `app/1` - the signed-in app shell: collapsible sidebar, top bar with
      breadcrumbs, ⌘K command palette, keyboard shortcuts and toasts.
    * `auth/1` - calm centred screens for sign-in, first-run setup and
      invitations.

  The root layout (`layouts/root.html.heex`) holds `<head>` and applies the
  theme and sidebar state before first paint.
  """
  use ReadoutWeb, :html

  alias Phoenix.LiveView.ColocatedHook
  alias Readout.Accounts.{Scope, User}
  alias Readout.Policy

  embed_templates "layouts/*"

  @doc false
  # The theme stored on the profile wins for signed-in users; otherwise the
  # root script falls back to localStorage, then to the system setting.
  def theme_pref(%Scope{user: %User{theme: theme}}), do: theme
  def theme_pref(_), do: nil

  ## App shell

  @doc """
  The signed-in app shell. Wrap every app LiveView in it:

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:documents}>
        <:crumb navigate={~p"/documents"}>Documents</:crumb>
        <:crumb>Q3 Report</:crumb>
        <:actions><.button>Share</.button></:actions>
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the sidebar item to highlight"
  attr :width, :string, default: "default", values: ~w(default wide full)

  slot :crumb do
    attr :navigate, :string
  end

  slot :actions
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="app-shell" phx-hook=".Shortcuts" class="min-h-dvh">
      <.sidebar current_scope={@current_scope} active={@active} />

      <div
        class="fixed inset-0 z-30 hidden bg-black/30 backdrop-blur-[1px] max-md:[[data-mobile-nav]_&]:block"
        phx-click={JS.dispatch("readout:close-mobile-nav")}
        aria-hidden="true"
      />

      <div class={[
        "flex min-h-dvh min-w-0 flex-col transition-[padding] duration-(--duration-base) ease-(--ease-out)",
        "md:pl-(--sidebar-width) sidebar-collapsed:md:pl-(--sidebar-rail)"
      ]}>
        <header class="sticky top-0 z-20 flex h-(--topbar-height) items-center gap-2 border-b border-border bg-canvas/85 px-3 backdrop-blur-md supports-[backdrop-filter]:bg-canvas/70">
          <.icon_button
            id="toggle-sidebar"
            icon="hero-bars-3-bottom-left"
            label={gettext("Toggle sidebar")}
            data-shortcut="["
            phx-click={JS.dispatch("readout:toggle-sidebar")}
          />
          <nav aria-label={gettext("Breadcrumb")} class="flex min-w-0 items-center gap-1 text-sm">
            <%= for {crumb, i} <- Enum.with_index(@crumb) do %>
              <.icon
                :if={i > 0}
                name="hero-chevron-right-micro"
                class="size-3.5 shrink-0 text-fg-faint"
              />
              <%= if crumb[:navigate] do %>
                <.link
                  navigate={crumb[:navigate]}
                  class="truncate rounded-md px-1.5 py-0.5 text-fg-muted transition-colors hover:bg-hover hover:text-fg"
                >
                  {render_slot(crumb)}
                </.link>
              <% else %>
                <span class="truncate px-1.5 py-0.5 font-medium text-fg" aria-current="page">
                  {render_slot(crumb)}
                </span>
              <% end %>
            <% end %>
          </nav>
          <div class="ml-auto flex items-center gap-1.5">{render_slot(@actions)}</div>
        </header>

        <main
          id="main"
          class={[
            "flex-1 px-4 py-6 [view-transition-name:main] sm:px-8 sm:py-8",
            @width == "default" && "mx-auto w-full max-w-5xl",
            @width == "wide" && "mx-auto w-full max-w-7xl"
          ]}
        >
          {render_slot(@inner_block)}
        </main>
      </div>

      <.live_component
        module={ReadoutWeb.CommandPalette}
        id="command-palette"
        current_scope={@current_scope}
      />
      <.shortcuts_sheet current_scope={@current_scope} />

      <%!-- Invisible shortcut targets for navigation (see the .Shortcuts hook). --%>
      <.link navigate={~p"/documents"} data-shortcut="g d" class="hidden" tabindex="-1"></.link>
      <.link navigate={~p"/analytics"} data-shortcut="g a" class="hidden" tabindex="-1"></.link>
      <.link navigate={~p"/settings/profile"} data-shortcut="g s" class="hidden" tabindex="-1"></.link>
      <.link
        :if={Policy.can?(@current_scope, :view_members, :workspace)}
        navigate={~p"/settings/members"}
        data-shortcut="g m"
        class="hidden"
        tabindex="-1"
      ></.link>
      <button
        type="button"
        class="hidden"
        tabindex="-1"
        data-shortcut="?"
        phx-click={open_dialog("shortcuts")}
      />
      <button
        type="button"
        class="hidden"
        tabindex="-1"
        data-shortcut="mod+k"
        phx-click={open_dialog("command-palette")}
      />

      <.flash_group flash={@flash} />
    </div>

    <script :type={ColocatedHook} name=".Shortcuts">
      // Keyboard shortcuts. Any element with data-shortcut="<keys>" is clicked
      // (or focused, for inputs) when its keys are pressed. Sequences like
      // "g d" are typed one key after another; "mod+k" is ⌘K / Ctrl+K.
      export default {
        mounted() {
          this.seq = ""
          this.onKey = (e) => {
            const mod = e.metaKey || e.ctrlKey
            if (mod && e.key.toLowerCase() === "k") return this.fire("mod+k", e)
            if (mod || e.altKey || e.repeat) return
            const t = e.target
            if (t.closest?.("input, textarea, select, [contenteditable]")) return
            if (document.querySelector("dialog[open]")) return
            if (e.key.length !== 1) return

            const key = e.key === "?" ? "?" : e.key.toLowerCase()
            const candidate = this.seq ? `${this.seq} ${key}` : key
            clearTimeout(this.timer)

            if (this.fire(candidate, e)) { this.seq = ""; return }
            if (this.hasPrefix(candidate)) {
              this.seq = candidate
              this.timer = setTimeout(() => this.seq = "", 900)
              return
            }
            this.seq = ""
            if (candidate !== key) {
              if (this.fire(key, e)) return
              if (this.hasPrefix(key)) {
                this.seq = key
                this.timer = setTimeout(() => this.seq = "", 900)
              }
            }
          }
          window.addEventListener("keydown", this.onKey)
        },
        find(selector) {
          return Array.from(document.querySelectorAll(selector))
        },
        hasPrefix(seq) {
          return this.find("[data-shortcut]").some(el => el.dataset.shortcut.startsWith(seq + " "))
        },
        fire(seq, e) {
          const el = this.find("[data-shortcut]").find(el => el.dataset.shortcut === seq && !el.disabled)
          if (!el) return false
          e.preventDefault()
          if (el.matches("input, textarea, select")) { el.focus(); el.select?.() }
          else el.click()
          return true
        },
        destroyed() {
          window.removeEventListener("keydown", this.onKey)
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end

  attr :current_scope, :map, required: true
  attr :active, :atom, default: nil

  defp sidebar(assigns) do
    assigns =
      assign(assigns,
        user: assigns.current_scope.user,
        workspace: Readout.Workspace.get_settings()
      )

    ~H"""
    <aside
      id="sidebar"
      class={[
        "fixed inset-y-0 left-0 z-40 flex w-(--sidebar-width) flex-col border-r border-border bg-sidebar",
        "transition-[width,transform] duration-(--duration-base) ease-(--ease-out)",
        "sidebar-collapsed:md:w-(--sidebar-rail)",
        "max-md:-translate-x-full max-md:shadow-xl max-md:[[data-mobile-nav]_&]:translate-x-0"
      ]}
    >
      <div class="flex h-(--topbar-height) shrink-0 items-center px-2.5">
        <.dropdown id="workspace-menu" align="start" class="w-full" menu_class="w-56">
          <:trigger>
            <button
              type="button"
              class="flex h-8 w-full min-w-0 cursor-pointer items-center gap-2 rounded-md px-1.5 text-left transition-colors hover:bg-hover active:bg-active"
            >
              <.logo class="size-5.5 shrink-0" />
              <span class="truncate text-sm font-semibold text-fg sidebar-collapsed:md:hidden">
                {@workspace.name}
              </span>
              <.icon
                name="hero-chevron-up-down-micro"
                class="ml-auto size-3.5 text-fg-subtle sidebar-collapsed:md:hidden"
              />
            </button>
          </:trigger>
          <:item label>{@user.email}</:item>
          <:item icon="hero-user-circle-mini" navigate={~p"/settings/profile"}>
            {gettext("Profile")}
          </:item>
          <:item
            :if={Policy.can?(@current_scope, :manage_workspace, :workspace)}
            icon="hero-building-office-2-mini"
            navigate={~p"/settings/workspace"}
          >
            {gettext("Workspace settings")}
          </:item>
          <:item icon="hero-command-line-mini" phx-click={open_dialog("shortcuts")} shortcut="?">
            {gettext("Keyboard shortcuts")}
          </:item>
          <:item separator />
          <:item
            icon="hero-arrow-right-start-on-rectangle-mini"
            href={~p"/users/log-out"}
            method="delete"
          >
            {gettext("Log out")}
          </:item>
        </.dropdown>
      </div>

      <div class="px-2.5 pb-2">
        <button
          type="button"
          phx-click={open_dialog("command-palette")}
          class="group flex h-8 w-full cursor-pointer items-center gap-2 rounded-md border border-border bg-surface px-2 text-sm text-fg-subtle shadow-xs transition-[border-color,color] hover:border-border-strong hover:text-fg-muted sidebar-collapsed:md:justify-center sidebar-collapsed:md:px-0"
          aria-label={gettext("Search and commands")}
        >
          <.icon name="hero-magnifying-glass-mini" class="size-4" />
          <span class="sidebar-collapsed:md:hidden">{gettext("Search…")}</span>
          <span class="ml-auto flex gap-0.5 sidebar-collapsed:md:hidden">
            <.kbd>mod</.kbd><.kbd>K</.kbd>
          </span>
        </button>
      </div>

      <nav
        class="flex flex-1 flex-col gap-0.5 overflow-y-auto px-2.5 py-1"
        aria-label={gettext("Main")}
      >
        <.nav_item
          navigate={~p"/documents"}
          icon="hero-document-text"
          active={@active == :documents}
          shortcut="G D"
        >
          {gettext("Documents")}
        </.nav_item>
        <.nav_item
          navigate={~p"/analytics"}
          icon="hero-chart-bar"
          active={@active == :analytics}
          shortcut="G A"
        >
          {gettext("Analytics")}
        </.nav_item>
        <.nav_item
          navigate={~p"/settings/profile"}
          icon="hero-cog-6-tooth"
          active={@active == :settings}
          shortcut="G S"
        >
          {gettext("Settings")}
        </.nav_item>
      </nav>

      <div class="flex items-center gap-2 border-t border-border p-2.5 sidebar-collapsed:md:flex-col">
        <.link
          navigate={~p"/settings/profile"}
          class="flex min-w-0 flex-1 items-center gap-2 rounded-md p-1 transition-colors hover:bg-hover"
        >
          <.avatar name={User.display_name(@user)} color={@user.avatar_color} size="sm" />
          <span class="min-w-0 sidebar-collapsed:md:hidden">
            <span class="block truncate text-sm font-medium text-fg">{User.display_name(@user)}</span>
            <span class="block truncate text-2xs text-fg-subtle">{role_label(@user.role)}</span>
          </span>
        </.link>
        <.theme_toggle id="sidebar-theme" compact />
      </div>
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :shortcut, :string, default: nil
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "group flex h-8 items-center gap-2.5 rounded-md px-2 text-sm font-medium",
        "transition-[background-color,color] duration-(--duration-fast)",
        "sidebar-collapsed:md:justify-center sidebar-collapsed:md:px-0",
        if(@active,
          do: "bg-active text-fg",
          else: "text-fg-muted hover:bg-hover hover:text-fg"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={[
          "size-4.5",
          if(@active, do: "text-fg", else: "text-fg-subtle group-hover:text-fg-muted")
        ]}
      />
      <span class="truncate sidebar-collapsed:md:sr-only">{render_slot(@inner_block)}</span>
      <span
        :if={@shortcut}
        class="ml-auto hidden text-2xs tracking-wider text-fg-faint group-hover:inline sidebar-collapsed:md:!hidden"
      >
        {@shortcut}
      </span>
    </.link>
    """
  end

  @doc """
  Header and tabs shared by all settings pages.
  """
  attr :current_scope, :map, required: true
  attr :active, :atom, required: true

  def settings_nav(assigns) do
    ~H"""
    <div class="mb-8">
      <h1 class="mb-4 text-2xl font-semibold text-fg">{gettext("Settings")}</h1>
      <.tabs id="settings-tabs" class="overflow-x-auto">
        <:tab navigate={~p"/settings/profile"} active={@active == :profile} id="tab-profile">
          {gettext("Profile")}
        </:tab>
        <:tab navigate={~p"/settings/account"} active={@active == :account} id="tab-account">
          {gettext("Email and password")}
        </:tab>
        <:tab
          :if={Policy.can?(@current_scope, :view_members, :workspace)}
          navigate={~p"/settings/members"}
          active={@active == :members}
          id="tab-members"
        >
          {gettext("Members")}
        </:tab>
        <:tab
          :if={Policy.can?(@current_scope, :view_audit_log, :workspace)}
          navigate={~p"/settings/audit"}
          active={@active == :audit}
          id="tab-audit"
        >
          {gettext("Audit log")}
        </:tab>
        <:tab
          :if={Policy.can?(@current_scope, :manage_workspace, :workspace)}
          navigate={~p"/settings/workspace"}
          active={@active == :workspace}
          id="tab-workspace"
        >
          {gettext("Workspace")}
        </:tab>
      </.tabs>
    </div>
    """
  end

  @doc "The role's display name."
  def role_label(:owner), do: gettext("Owner")
  def role_label(:admin), do: gettext("Admin")
  def role_label(:member), do: gettext("Member")
  def role_label(:observer), do: gettext("Observer")

  @doc "One line describing what a role can do."
  def role_description(:owner),
    do: gettext("Everything, including workspace settings and admins.")

  def role_description(:admin), do: gettext("Manages people and sees every document.")

  def role_description(:member),
    do: gettext("Uploads documents, shares links, sees their analytics.")

  def role_description(:observer), do: gettext("Read-only access to documents and analytics.")

  ## Keyboard shortcuts sheet

  attr :current_scope, :map, required: true

  defp shortcuts_sheet(assigns) do
    ~H"""
    <.sheet id="shortcuts" title={gettext("Keyboard shortcuts")} width="24rem">
      <div class="space-y-6">
        <section :for={{group, items} <- shortcut_groups()}>
          <h3 class="mb-2 text-xs font-medium text-fg-subtle">{group}</h3>
          <ul class="divide-y divide-border rounded-lg border border-border">
            <li
              :for={{label, keys} <- items}
              class="flex items-center justify-between px-3 py-2 text-sm"
            >
              <span class="text-fg">{label}</span>
              <span class="flex items-center gap-1">
                <%= for {key, i} <- Enum.with_index(keys) do %>
                  <span :if={i > 0 and key != "+"} class="text-2xs text-fg-faint">
                    {gettext("then")}
                  </span>
                  <.kbd>{key}</.kbd>
                <% end %>
              </span>
            </li>
          </ul>
        </section>
      </div>
    </.sheet>
    """
  end

  defp shortcut_groups do
    [
      {gettext("General"),
       [
         {gettext("Open command palette"), ["mod", "K"]},
         {gettext("Show keyboard shortcuts"), ["?"]},
         {gettext("Toggle sidebar"), ["["]},
         {gettext("Focus search"), ["/"]}
       ]},
      {gettext("Go to"),
       [
         {gettext("Documents"), ["G", "D"]},
         {gettext("Analytics"), ["G", "A"]},
         {gettext("Settings"), ["G", "S"]},
         {gettext("Members"), ["G", "M"]}
       ]}
    ]
  end

  ## Theme toggle

  @doc """
  Switches between system, light and dark. Applies instantly on the client
  and, when signed in, saves the choice to the profile.
  """
  attr :id, :string, required: true
  attr :compact, :boolean, default: false

  def theme_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label={gettext("Theme")}
      class={[
        "relative inline-flex shrink-0 rounded-md bg-hover p-0.5 shadow-[inset_0_0_0_1px_var(--color-border)]",
        @compact && "sidebar-collapsed:md:flex-col"
      ]}
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", gettext("System theme")},
            {"light", "hero-sun-micro", gettext("Light theme")},
            {"dark", "hero-moon-micro", gettext("Dark theme")}
          ]
        }
        type="button"
        role="radio"
        aria-label={label}
        title={label}
        data-theme-option={theme}
        phx-click={set_theme(theme) |> JS.push("shell:set_theme", value: %{theme: theme})}
        class={[
          "flex size-6 cursor-pointer items-center justify-center rounded-[5px] text-fg-subtle",
          "transition-[background-color,color,box-shadow,transform] duration-(--duration-fast) active:scale-90 hover:text-fg",
          "[[data-theme-pref=system]_&[data-theme-option=system]]:bg-surface [[data-theme-pref=system]_&[data-theme-option=system]]:text-fg [[data-theme-pref=system]_&[data-theme-option=system]]:shadow-sm",
          "[[data-theme-pref=light]_&[data-theme-option=light]]:bg-surface [[data-theme-pref=light]_&[data-theme-option=light]]:text-fg [[data-theme-pref=light]_&[data-theme-option=light]]:shadow-sm",
          "[[data-theme-pref=dark]_&[data-theme-option=dark]]:bg-surface [[data-theme-pref=dark]_&[data-theme-option=dark]]:text-fg [[data-theme-pref=dark]_&[data-theme-option=dark]]:shadow-sm"
        ]}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  ## Auth layout

  @doc """
  A calm, centred layout for screens outside the app: sign in, first-run
  setup, invitations.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :width, :string, default: "24rem"
  slot :inner_block, required: true
  slot :footer

  def auth(assigns) do
    ~H"""
    <div class="relative flex min-h-dvh flex-col items-center justify-center bg-canvas px-4 py-12">
      <div
        class="pointer-events-none absolute inset-x-0 top-0 h-72 bg-[radial-gradient(60%_100%_at_50%_0%,var(--color-accent-soft),transparent)] opacity-70"
        aria-hidden="true"
      />
      <div class="relative w-full animate-fade-in" style={"max-width: #{@width}"}>
        <div class="mb-8 flex items-center justify-center gap-2.5">
          <.logo class="size-7" />
          <span class="text-lg font-semibold tracking-tight text-fg">Readout</span>
        </div>
        <div class="rounded-xl border border-border bg-surface p-6 shadow-md sm:p-8">
          {render_slot(@inner_block)}
        </div>
        <div :if={@footer != []} class="mt-6 text-center text-sm text-fg-muted">
          {render_slot(@footer)}
        </div>
      </div>
      <div class="absolute right-4 bottom-4">
        <.theme_toggle id="auth-theme" />
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  ## Logo

  attr :class, :any, default: "size-6"

  def logo(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={@class} aria-hidden="true">
      <rect width="24" height="24" rx="6" fill="var(--color-accent)" />
      <path
        d="M8 6.5h5.2l3.3 3.3V17a.5.5 0 0 1-.5.5H8a.5.5 0 0 1-.5-.5V7a.5.5 0 0 1 .5-.5Z"
        fill="var(--color-on-accent)"
        fill-opacity="0.95"
      />
      <path d="M13 6.5v3.3h3.5" fill="none" stroke="var(--color-accent)" stroke-width="1" />
      <rect x="9.3" y="12" width="5.4" height="1.1" rx=".55" fill="var(--color-accent)" />
      <rect x="9.3" y="14.2" width="3.6" height="1.1" rx=".55" fill="var(--color-accent)" />
    </svg>
    """
  end

  ## Toasts

  @doc """
  Shows the flash as toasts, plus the reconnecting notices.

  The region is a manual popover so it sits in the top layer, above open
  dialogs.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      popover="manual"
      phx-hook=".ToastRegion"
      aria-live="polite"
      class="pointer-events-none fixed top-auto right-4 bottom-4 left-auto m-0 flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-2 overflow-visible border-0 bg-transparent p-0"
    >
      <.toast id="flash-info" kind={:info} flash={@flash} />
      <.toast id="flash-error" kind={:error} flash={@flash} />

      <.toast
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        autodismiss={false}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
      </.toast>

      <.toast
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        autodismiss={false}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
      </.toast>

      <div id="client-toasts" phx-update="ignore" class="flex flex-col gap-2"></div>
      <.toast_template />
    </div>
    <script :type={ColocatedHook} name=".ToastRegion">
      // Keep the toast region in the top layer and above any open dialog:
      // re-showing a popover moves it to the top of the stack. Only needed
      // while a dialog is open (re-showing replays the toasts' entry motion).
      export default {
        mounted() {
          this.show = () => {
            if (!this.el.showPopover) return
            try { if (this.el.matches(":popover-open")) this.el.hidePopover() } catch (_e) {}
            try { this.el.showPopover() } catch (_e) {}
          }
          this.raise = () => document.querySelector("dialog[open]") && this.show()
          this.show()
          this.observer = new MutationObserver(this.raise)
          this.observer.observe(this.el, {childList: true})
          this.observer.observe(this.el.querySelector("#client-toasts"), {childList: true})
          window.addEventListener("readout:dialog-open", this.onDialog = () => setTimeout(this.raise))
        },
        destroyed() {
          this.observer?.disconnect()
          window.removeEventListener("readout:dialog-open", this.onDialog)
        }
      }
    </script>
    """
  end
end
