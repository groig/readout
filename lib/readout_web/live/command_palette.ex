defmodule ReadoutWeb.CommandPalette do
  @moduledoc """
  The ⌘K / Ctrl+K command palette: jump anywhere, run actions, switch theme.

  A LiveComponent because it is a self-contained, stateful widget (query and
  results) rendered by the shell on every page. Filtering runs on the server
  (so it can search documents); arrow keys and Enter are handled on the client
  by the colocated `.Palette` hook for instant feedback.
  """
  use ReadoutWeb, :live_component

  alias Phoenix.LiveView.ColocatedHook
  alias Readout.Policy

  @impl true
  def mount(socket) do
    {:ok, assign(socket, query: "")}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :groups, results(socket.assigns.current_scope, socket.assigns.query))}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(query: query)
     |> assign(:groups, results(socket.assigns.current_scope, query))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(query: "")
     |> assign(:groups, results(socket.assigns.current_scope, ""))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="ui-dialog ui-palette"
      aria-label={gettext("Command palette")}
      phx-hook=".Palette"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-on-close={JS.push("reset", target: @myself)}
    >
      <div class="flex max-h-[inherit] flex-col">
        <form
          id="palette-form"
          phx-change="search"
          phx-submit="search"
          phx-target={@myself}
          class="flex items-center gap-2.5 border-b border-border px-4"
        >
          <.icon name="hero-magnifying-glass" class="size-4.5 text-fg-subtle" />
          <input
            id="palette-input"
            type="text"
            name="q"
            value={@query}
            autofocus
            autocomplete="off"
            spellcheck="false"
            role="combobox"
            aria-expanded="true"
            aria-controls="palette-results"
            placeholder={gettext("Search or jump to…")}
            class="h-13 flex-1 bg-transparent text-md text-fg placeholder:text-fg-subtle focus:outline-none"
          />
          <.kbd>esc</.kbd>
        </form>

        <div id="palette-results" role="listbox" class="min-h-0 flex-1 overflow-y-auto p-1.5">
          <div :if={@groups == []} class="px-3 py-10 text-center text-sm text-fg-muted">
            {gettext("No results for “%{query}”", query: @query)}
          </div>
          <section :for={{group, commands} <- @groups} class="pb-1">
            <h3 class="px-2.5 pt-2 pb-1 text-2xs font-medium text-fg-subtle">{group}</h3>
            <button
              :for={command <- commands}
              id={"palette-#{command.id}"}
              type="button"
              role="option"
              aria-selected="false"
              phx-click={run(command)}
              class="flex h-9 w-full cursor-pointer items-center gap-2.5 rounded-md px-2.5 text-left text-sm text-fg transition-colors duration-75 aria-selected:bg-hover"
            >
              <.icon name={command.icon} class="size-4 text-fg-subtle" />
              <span class="flex-1 truncate">{command.label}</span>
              <span :if={command[:hint]} class="text-xs text-fg-subtle">{command.hint}</span>
              <span :if={command[:keys]} class="flex gap-0.5">
                <.kbd :for={key <- command.keys}>{key}</.kbd>
              </span>
            </button>
          </section>
        </div>

        <footer class="flex items-center gap-4 border-t border-border bg-inset px-4 py-2 text-2xs text-fg-subtle">
          <span class="flex items-center gap-1"><.kbd>↑</.kbd><.kbd>↓</.kbd>
          {gettext("navigate")}</span>
          <span class="flex items-center gap-1"><.kbd>↵</.kbd>
          {gettext("open")}</span>
          <span class="ml-auto flex items-center gap-1"><.kbd>?</.kbd>
          {gettext("all shortcuts")}</span>
        </footer>
      </div>
      <.link id="palette-logout" href={~p"/users/log-out"} method="delete" class="hidden"></.link>
      <script :type={ColocatedHook} name=".Palette">
        export default {
          mounted() {
            this.input = this.el.querySelector("#palette-input")
            this.active = 0
            this.input.addEventListener("keydown", e => {
              if (e.key === "ArrowDown") { e.preventDefault(); this.setActive(this.active + 1) }
              else if (e.key === "ArrowUp") { e.preventDefault(); this.setActive(this.active - 1) }
              else if (e.key === "Enter") { e.preventDefault(); this.options()[this.active]?.click() }
            })
            this.el.addEventListener("mousemove", e => {
              const option = e.target.closest("[role=option]")
              if (option) this.setActive(this.options().indexOf(option), false)
            })
            this.el.addEventListener("close", () => { this.input.value = "" })
            this.setActive(0)
          },
          updated() { this.setActive(0) },
          options() { return Array.from(this.el.querySelectorAll("[role=option]")) },
          setActive(index, scroll = true) {
            const options = this.options()
            if (!options.length) return this.input.removeAttribute("aria-activedescendant")
            this.active = (index + options.length) % options.length
            options.forEach((o, i) => o.setAttribute("aria-selected", i === this.active ? "true" : "false"))
            this.input.setAttribute("aria-activedescendant", options[this.active].id)
            if (scroll) options[this.active].scrollIntoView({block: "nearest"})
          }
        }
      </script>
    </dialog>
    """
  end

  defp run(%{action: {:navigate, path}}),
    do: close_dialog("command-palette") |> JS.navigate(path)

  defp run(%{action: {:js, js}}), do: close_dialog("command-palette") |> then(&concat(&1, js))

  defp concat(%JS{ops: a}, %JS{ops: b}), do: %JS{ops: a ++ b}

  ## Commands

  @doc false
  def results(scope, query) do
    terms = query |> normalize() |> String.split(" ", trim: true)

    (document_commands(scope, query) ++ commands(scope))
    |> Enum.filter(fn command ->
      # Documents are already matched by the server-side search.
      command.group == gettext("Documents") or
        Enum.all?(
          terms,
          &String.contains?(
            normalize(command.label <> " " <> Map.get(command, :keywords, "")),
            &1
          )
        )
    end)
    |> Enum.group_by(& &1.group)
    |> then(fn grouped ->
      for group <- group_order(), commands = grouped[group], do: {group, commands}
    end)
  end

  defp group_order,
    do: [gettext("Documents"), gettext("Go to"), gettext("Actions"), gettext("Theme")]

  # Documents matching the query (title or page text), when there is one.
  defp document_commands(nil, _query), do: []

  defp document_commands(scope, query) do
    if String.trim(query) == "" do
      []
    else
      scope
      |> Readout.Documents.list_documents(query: query)
      |> Enum.take(6)
      |> Enum.map(fn doc ->
        %{
          id: "doc-#{doc.id}",
          group: gettext("Documents"),
          label: doc.title,
          icon: "hero-document-text",
          hint:
            doc.current_version &&
              ngettext("%{count} page", "%{count} pages", doc.current_version.page_count),
          action: {:navigate, ~p"/documents/#{doc.id}"}
        }
      end)
    end
  end

  defp commands(nil), do: []

  defp commands(scope) do
    go = gettext("Go to")
    actions = gettext("Actions")
    theme = gettext("Theme")

    [
      %{
        id: "go-documents",
        group: go,
        label: gettext("Documents"),
        icon: "hero-document-text",
        keys: ["G", "D"],
        action: {:navigate, ~p"/documents"}
      },
      %{
        id: "go-analytics",
        group: go,
        label: gettext("Analytics"),
        icon: "hero-chart-bar",
        keys: ["G", "A"],
        action: {:navigate, ~p"/analytics"}
      },
      %{
        id: "go-profile",
        group: go,
        label: gettext("Profile"),
        keywords: gettext("settings preferences language time zone"),
        icon: "hero-user-circle",
        keys: ["G", "S"],
        action: {:navigate, ~p"/settings/profile"}
      },
      %{
        id: "go-account",
        group: go,
        label: gettext("Email and password"),
        keywords: gettext("settings account security"),
        icon: "hero-key",
        action: {:navigate, ~p"/settings/account"}
      },
      Policy.can?(scope, :view_members, :workspace) &&
        %{
          id: "go-members",
          group: go,
          label: gettext("Members"),
          keywords: gettext("settings people team users roles"),
          icon: "hero-users",
          keys: ["G", "M"],
          action: {:navigate, ~p"/settings/members"}
        },
      Policy.can?(scope, :view_audit_log, :workspace) &&
        %{
          id: "go-audit",
          group: go,
          label: gettext("Audit log"),
          keywords: gettext("settings history security"),
          icon: "hero-shield-check",
          action: {:navigate, ~p"/settings/audit"}
        },
      Policy.can?(scope, :manage_workspace, :workspace) &&
        %{
          id: "go-workspace",
          group: go,
          label: gettext("Workspace settings"),
          keywords: gettext("settings notifications ownership"),
          icon: "hero-building-office-2",
          action: {:navigate, ~p"/settings/workspace"}
        },
      Policy.can?(scope, :invite, :workspace) &&
        %{
          id: "invite",
          group: actions,
          label: gettext("Invite people"),
          keywords: gettext("member user add team"),
          icon: "hero-user-plus",
          action: {:navigate, ~p"/settings/members?invite=1"}
        },
      Policy.can?(scope, :upload_document, :workspace) &&
        %{
          id: "upload",
          group: actions,
          label: gettext("Upload document"),
          keywords: gettext("new file pdf word powerpoint add"),
          icon: "hero-arrow-up-tray",
          keys: ["U"],
          action: {:js, JS.dispatch("readout:pick-file")}
        },
      %{
        id: "toggle-sidebar",
        group: actions,
        label: gettext("Toggle sidebar"),
        icon: "hero-view-columns",
        keys: ["["],
        action: {:js, JS.dispatch("readout:toggle-sidebar")}
      },
      %{
        id: "shortcuts",
        group: actions,
        label: gettext("Keyboard shortcuts"),
        icon: "hero-command-line",
        keys: ["?"],
        action: {:js, open_dialog("shortcuts")}
      },
      %{
        id: "log-out",
        group: actions,
        label: gettext("Log out"),
        keywords: gettext("sign out"),
        icon: "hero-arrow-right-start-on-rectangle",
        action: {:js, JS.dispatch("click", to: "#palette-logout")}
      },
      theme_command("light", gettext("Light theme"), "hero-sun", theme),
      theme_command("dark", gettext("Dark theme"), "hero-moon", theme),
      theme_command("system", gettext("System theme"), "hero-computer-desktop", theme)
    ]
    |> Enum.filter(& &1)
  end

  defp theme_command(value, label, icon, group) do
    %{
      id: "theme-#{value}",
      group: group,
      label: label,
      keywords: gettext("appearance mode switch"),
      icon: icon,
      action: {:js, set_theme(value) |> JS.push("shell:set_theme", value: %{theme: value})}
    }
  end

  @doc false
  # Lowercase and strip accents so "configuracion" finds "Configuración".
  def normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end
end
