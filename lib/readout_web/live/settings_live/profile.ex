defmodule ReadoutWeb.SettingsLive.Profile do
  @moduledoc "Profile and preferences: name, avatar colour, language, time zone, theme, notifications."
  use ReadoutWeb, :live_view

  alias Readout.Accounts
  alias Readout.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <:crumb navigate={~p"/settings/profile"}>{gettext("Settings")}</:crumb>
      <:crumb>{gettext("Profile")}</:crumb>

      <Layouts.settings_nav current_scope={@current_scope} active={:profile} />

      <.form for={@form} id="profile-form" phx-change="validate" phx-submit="save">
        <div class="space-y-8">
          <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
            <div>
              <h2 class="text-md font-semibold text-fg">{gettext("Profile")}</h2>
              <p class="mt-1 text-sm text-fg-muted">
                {gettext("How you appear to your team and in the audit log.")}
              </p>
            </div>
            <.card>
              <div class="flex items-center gap-4 pb-5">
                <.avatar
                  id="profile-avatar"
                  name={preview_name(@form, @current_scope.user)}
                  color={@form[:avatar_color].value}
                  size="xl"
                />
                <div class="min-w-0">
                  <p class="truncate font-medium text-fg">
                    {preview_name(@form, @current_scope.user)}
                  </p>
                  <p class="truncate text-sm text-fg-muted">{@current_scope.user.email}</p>
                  <.badge class="mt-1.5">{Layouts.role_label(@current_scope.user.role)}</.badge>
                </div>
              </div>
              <div class="space-y-5 border-t border-border pt-5">
                <.input field={@form[:name]} label={gettext("Name")} autocomplete="name" />
                <fieldset>
                  <legend class="mb-2 text-sm font-medium text-fg">{gettext("Avatar colour")}</legend>
                  <div class="flex flex-wrap gap-2" role="radiogroup">
                    <label
                      :for={color <- User.avatar_colors()}
                      class="cursor-pointer rounded-full p-0.5 ring-2 ring-transparent transition-[box-shadow,transform] duration-(--duration-fast) hover:scale-110 has-checked:ring-accent has-focus-visible:ring-ring"
                      title={color}
                    >
                      <input
                        type="radio"
                        name={@form[:avatar_color].name}
                        value={color}
                        checked={@form[:avatar_color].value == color}
                        class="sr-only"
                      />
                      <.avatar
                        name={preview_name(@form, @current_scope.user)}
                        color={color}
                        size="md"
                      />
                    </label>
                  </div>
                </fieldset>
              </div>
            </.card>
          </section>

          <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
            <div>
              <h2 class="text-md font-semibold text-fg">{gettext("Preferences")}</h2>
              <p class="mt-1 text-sm text-fg-muted">
                {gettext("Language, time zone and appearance.")}
              </p>
            </div>
            <.card>
              <div class="space-y-5">
                <.input
                  field={@form[:locale]}
                  type="select"
                  label={gettext("Language")}
                  options={[
                    {gettext("Automatic (from your browser)"), "auto"},
                    {"English", "en"},
                    {"Español", "es"}
                  ]}
                />
                <.input
                  field={@form[:timezone]}
                  type="select"
                  label={gettext("Time zone")}
                  hint={gettext("Currently showing times in %{zone}.", zone: @current_scope.timezone)}
                  prompt={gettext("Automatic (from your browser)")}
                  options={@timezones}
                />
                <.input
                  field={@form[:theme]}
                  type="segmented"
                  label={gettext("Theme")}
                  options={[
                    {gettext("System"), "system"},
                    {gettext("Light"), "light"},
                    {gettext("Dark"), "dark"}
                  ]}
                />
              </div>
            </.card>
          </section>

          <section class="grid gap-6 md:grid-cols-[14rem_1fr]">
            <div>
              <h2 class="text-md font-semibold text-fg">{gettext("Notifications")}</h2>
              <p class="mt-1 text-sm text-fg-muted">
                {gettext("Choose per document later, from each document's menu.")}
              </p>
            </div>
            <.card>
              <.input
                field={@form[:notifications_enabled]}
                type="switch"
                label={gettext("Notify me about my documents")}
                hint={gettext("When someone opens a document you own, and when they finish reading.")}
              />
            </.card>
          </section>

          <div class="flex justify-end gap-2 border-t border-border pt-6">
            <.button type="submit" variant="primary" id="save-profile" disabled={!@dirty}>
              {gettext("Save changes")}
            </.button>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, gettext("Profile"))
     |> assign(:timezones, Readout.TimeZones.all())
     |> assign(:dirty, false)
     |> assign(:form, to_form(Accounts.change_profile(user)))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> Accounts.change_profile(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), dirty: changeset.changes != %{})}
  end

  def handle_event("save", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope
    previous = scope.user

    case Accounts.update_profile(scope, normalize(params)) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_scope, %{scope | user: user})
          |> assign(:form, to_form(Accounts.change_profile(user)))
          |> assign(:dirty, false)
          |> push_event("set-theme", %{theme: user.theme})

        if user.locale != previous.locale or user.timezone != previous.timezone do
          # Language and time zone apply to the whole page: reload it.
          {:noreply,
           socket
           |> put_flash(:info, gettext("Preferences saved."))
           |> redirect(to: ~p"/settings/profile")}
        else
          {:noreply, put_flash(socket, :info, gettext("Profile saved."))}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # An empty time zone means "automatic".
  defp normalize(params) do
    Map.update(params, "timezone", nil, fn
      "" -> nil
      tz -> tz
    end)
  end

  defp preview_name(form, user) do
    case form[:name].value do
      name when is_binary(name) and name != "" -> name
      _ -> user.email
    end
  end
end
