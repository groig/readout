defmodule ReadoutWeb.DocumentLive.LinkComponents do
  @moduledoc "The Links tab of a document: the list of share links and their settings sheet."
  use ReadoutWeb, :html

  alias Readout.Links.Link

  @doc "The public URL of a link."
  def link_url(%Link{slug: slug}), do: url(~p"/v/#{slug}")

  attr :links, :any, required: true, doc: "stream of links"
  attr :count, :integer, required: true
  attr :can_edit, :boolean, required: true
  attr :scope, :any, required: true

  def links_table(assigns) do
    ~H"""
    <div :if={@count == 0} class="rounded-xl border border-dashed border-border-strong">
      <.empty_state id="links-empty" icon="hero-link" title={gettext("No links yet")}>
        {gettext(
          "Create a link for each person or group you share with, so you can see who read what."
        )}
        <:actions :if={@can_edit}>
          <.button variant="primary" icon="hero-plus-mini" phx-click="new_link">
            {gettext("Create link")}
          </.button>
        </:actions>
      </.empty_state>
    </div>
    <.table :if={@count > 0} id="links" rows={@links}>
      <:col :let={{_id, link}} label={gettext("Link")}>
        <div class="min-w-0">
          <p class="flex items-center gap-2 font-medium text-fg">
            {link.name}
            <.badge :if={!link.enabled}>{gettext("Disabled")}</.badge>
            <.badge :if={link.enabled and Link.expired?(link)} tone="warning">
              {gettext("Expired")}
            </.badge>
          </p>
          <p class="max-w-72 truncate font-mono text-xs text-fg-subtle">/v/{link.slug}</p>
        </div>
      </:col>
      <:col :let={{_id, link}} label={gettext("Protection")}>
        <span class="flex items-center gap-1.5 text-fg-subtle">
          <.tooltip :if={Link.password?(link)} text={gettext("Password")}>
            <.icon name="hero-lock-closed-mini" class="size-4" />
          </.tooltip>
          <.tooltip
            :if={link.require_email and !link.require_verification}
            text={gettext("Email required")}
          >
            <.icon name="hero-envelope-mini" class="size-4" />
          </.tooltip>
          <.tooltip :if={link.require_verification} text={gettext("Verified email")}>
            <.icon name="hero-shield-check-mini" class="size-4 text-success" />
          </.tooltip>
          <.tooltip :if={link.allow_download} text={gettext("Downloads allowed")}>
            <.icon name="hero-arrow-down-tray-mini" class="size-4" />
          </.tooltip>
          <.tooltip :if={link.watermark} text={gettext("Watermark")}>
            <.icon name="hero-finger-print-mini" class="size-4" />
          </.tooltip>
          <.tooltip
            :if={link.expires_at}
            text={gettext("Expires %{date}", date: Format.date(link.expires_at, @scope))}
          >
            <.icon name="hero-clock-mini" class="size-4" />
          </.tooltip>
          <span
            :if={
              !Link.password?(link) and !link.require_email and !link.allow_download and
                !link.watermark and !link.expires_at
            }
            class="text-xs"
          >
            {gettext("Open")}
          </span>
        </span>
      </:col>
      <:col :let={{_id, link}} label={gettext("Visits")} numeric>{link.visit_count}</:col>
      <:col :let={{_id, link}} label={gettext("Created")} class="text-fg-muted">
        <.relative_time at={link.inserted_at} scope={@scope} />
      </:col>
      <:action :let={{id, link}}>
        <.button
          id={"#{id}-copy"}
          size="sm"
          variant="ghost"
          icon="hero-clipboard-document-mini"
          phx-click={copy(link_url(link), gettext("Link copied"))}
        >
          {gettext("Copy")}
        </.button>
        <.icon_button
          :if={@can_edit}
          id={"#{id}-edit"}
          icon="hero-adjustments-horizontal-mini"
          label={gettext("Link settings")}
          phx-click="edit_link"
          phx-value-id={link.id}
        />
      </:action>
    </.table>
    """
  end

  attr :form, :any, required: true
  attr :link, Link, required: true
  attr :mail_enabled, :boolean, required: true
  attr :office?, :boolean, required: true
  attr :expires_on, :string, default: ""

  def link_sheet(assigns) do
    assigns = assign(assigns, :new?, is_nil(assigns.link.id))

    ~H"""
    <.sheet
      id="link-sheet"
      show
      width="30rem"
      title={if @new?, do: gettext("New link"), else: gettext("Link settings")}
      description={!@new? && link_url(@link)}
      on_close={JS.push("close_link")}
    >
      <.form
        for={@form}
        id="link-form"
        phx-change="validate_link"
        phx-submit="save_link"
        class="space-y-6"
      >
        <.input
          field={@form[:name]}
          label={gettext("Name")}
          placeholder={gettext("e.g. Client X, Investors")}
          hint={gettext("Only your team sees it, to tell links apart in analytics.")}
          autocomplete="off"
          phx-mounted={@new? && JS.focus()}
        />

        <section class="space-y-4">
          <h3 class="text-xs font-medium text-fg-subtle">{gettext("Access")}</h3>
          <.input
            :if={!@new?}
            field={@form[:enabled]}
            type="switch"
            label={gettext("Link enabled")}
            hint={gettext("Turn off to stop it working right away.")}
          />
          <.input
            name="link[expires_on]"
            id="link_expires_on"
            type="date"
            value={@expires_on}
            label={gettext("Expires on")}
            hint={gettext("Optional. The link stops working at the end of that day.")}
            errors={translate_errors(@form.errors, :expires_at)}
          />
          <div class="space-y-1.5">
            <%= if Link.password?(@link) and !Phoenix.HTML.Form.normalize_value("checkbox", @form[:remove_password].value) do %>
              <div class="flex items-center justify-between rounded-md border border-border bg-inset px-3 py-2 text-sm">
                <span class="flex items-center gap-2 text-fg">
                  <.icon name="hero-lock-closed-mini" class="size-4 text-fg-subtle" />
                  {gettext("Password protected")}
                </span>
                <.input field={@form[:remove_password]} type="checkbox" label={gettext("Remove")} />
              </div>
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("New password")}
                hint={gettext("Leave empty to keep the current one.")}
                autocomplete="new-password"
              />
            <% else %>
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("Password")}
                hint={gettext("Optional. Share it separately from the link.")}
                autocomplete="new-password"
              />
              <input
                :if={Link.password?(@link)}
                type="hidden"
                name="link[remove_password]"
                value="true"
              />
            <% end %>
          </div>
        </section>

        <section class="space-y-4">
          <h3 class="text-xs font-medium text-fg-subtle">{gettext("Viewers")}</h3>
          <.input
            field={@form[:require_email]}
            type="switch"
            label={gettext("Ask for an email")}
            hint={gettext("Viewers enter their email before reading.")}
          />
          <.input
            field={@form[:require_verification]}
            type="switch"
            label={gettext("Verify the email")}
            hint={
              if @mail_enabled,
                do: gettext("We email a 6-digit code, so analytics show a real identity."),
                else: gettext("Needs email (SMTP) to be configured on the server.")
            }
            disabled={!@mail_enabled}
          />
          <div :if={field_on?(@form, :require_email)} class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:allow_list_text]}
              type="textarea"
              label={gettext("Only allow")}
              placeholder="client.com\nana@partner.com"
              hint={gettext("Emails or domains, one per line. Empty allows anyone.")}
              rows="3"
            />
            <.input
              field={@form[:deny_list_text]}
              type="textarea"
              label={gettext("Block")}
              placeholder="competitor.com"
              hint={gettext("Always refused.")}
              rows="3"
            />
          </div>
        </section>

        <section class="space-y-4">
          <h3 class="text-xs font-medium text-fg-subtle">{gettext("Document")}</h3>
          <.input
            field={@form[:allow_download]}
            type="switch"
            label={gettext("Allow download")}
            hint={gettext("Viewers can download the PDF.")}
          />
          <.input
            :if={@office? and field_on?(@form, :allow_download)}
            field={@form[:allow_original_download]}
            type="switch"
            label={gettext("Also the original file")}
            hint={gettext("The Word or PowerPoint file as uploaded.")}
          />
          <.input
            field={@form[:watermark]}
            type="switch"
            label={gettext("Watermark")}
            hint={
              gettext(
                "Shows the viewer's email and the time over every page. A deterrent, not real protection."
              )
            }
          />
        </section>
      </.form>
      <:footer>
        <.button phx-click={close_dialog("link-sheet")}>{gettext("Cancel")}</.button>
        <.button type="submit" form="link-form" variant="primary" id="save-link">
          {if @new?, do: gettext("Create link"), else: gettext("Save")}
        </.button>
      </:footer>
    </.sheet>
    """
  end

  defp field_on?(form, field),
    do: Phoenix.HTML.Form.normalize_value("checkbox", form[field].value) == true
end
