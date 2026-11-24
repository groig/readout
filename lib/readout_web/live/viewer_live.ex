defmodule ReadoutWeb.ViewerLive do
  @moduledoc """
  The public viewer at `/v/:slug`: the gate (password, email, verification
  code), then the document.

  States: `:unavailable` (missing, disabled, expired or not ready), `:gate`,
  `:code` (waiting for the emailed code) and `:reading`. A visit starts when
  the reader is connected and through the gate.
  """
  use ReadoutWeb, :live_view

  import ReadoutWeb.ViewerComponents

  alias Readout.Documents
  alias Readout.Documents.{Pdf, Version}
  alias Readout.Links
  alias Readout.Links.Link
  alias ReadoutWeb.{ClientIP, ViewerAccess}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-canvas" data-viewer-standalone>
      <%= case @state do %>
        <% :unavailable -> %>
          <.public_card workspace={@workspace}>
            <div id="link-unavailable" class="text-center">
              <div class="mx-auto mb-4 flex size-11 items-center justify-center rounded-xl border border-border bg-inset text-fg-subtle">
                <.icon name={unavailable_icon(@reason)} class="size-5" />
              </div>
              <h1 class="text-lg font-semibold text-fg">{unavailable_title(@reason)}</h1>
              <p class="mt-1 text-sm text-fg-muted">{unavailable_text(@reason)}</p>
            </div>
          </.public_card>
        <% :gate -> %>
          <.public_card workspace={@workspace}>
            <.doc_heading link={@link} workspace={@workspace} />
            <.form
              for={@gate_form}
              id="gate-form"
              phx-submit="gate"
              class="space-y-4"
            >
              <.input
                :if={@link.require_email}
                field={@gate_form[:email]}
                type="email"
                label={gettext("Your email")}
                autocomplete="email"
                required
                readonly={!!@known_email}
                phx-mounted={!@known_email && JS.focus()}
              />
              <.input
                :if={Link.password?(@link)}
                field={@gate_form[:password]}
                type="password"
                label={gettext("Password")}
                autocomplete="off"
                required
                phx-mounted={(@known_email || !@link.require_email) && JS.focus()}
              />
              <p :if={@gate_error} id="gate-error" class="text-sm text-danger-fg">{@gate_error}</p>
              <.button type="submit" variant="primary" size="lg" class="w-full" id="gate-submit">
                {if @link.require_verification and !@known_email,
                  do: gettext("Continue"),
                  else: gettext("View document")}
              </.button>
              <p :if={@link.require_email} class="text-center text-xs text-fg-subtle">
                {gettext("%{workspace} will see your email and how you read this document.",
                  workspace: @workspace.name
                )}
              </p>
            </.form>
            <.access_form :if={@grant_token} slug={@link.slug} token={@grant_token} />
          </.public_card>
        <% :code -> %>
          <.public_card workspace={@workspace}>
            <.doc_heading link={@link} workspace={@workspace} />
            <.form for={@code_form} id="code-form" phx-submit="verify" class="space-y-4">
              <p class="text-sm text-fg-muted">
                {gettext("We sent a 6-digit code to %{email}. It expires in 10 minutes.",
                  email: @email
                )}
              </p>
              <input
                id="code-input"
                name="code"
                type="text"
                inputmode="numeric"
                autocomplete="one-time-code"
                pattern="[0-9 ]*"
                maxlength="7"
                required
                aria-label={gettext("Verification code")}
                phx-mounted={JS.focus()}
                class="h-14 w-full rounded-lg border border-border-strong bg-surface text-center font-mono text-2xl tracking-[0.5em] text-fg shadow-xs focus:border-accent focus:ring-3 focus:ring-accent/20 focus:outline-none"
              />
              <p :if={@gate_error} id="gate-error" class="text-sm text-danger-fg">{@gate_error}</p>
              <.button type="submit" variant="primary" size="lg" class="w-full" id="verify-submit">
                {gettext("Verify and view")}
              </.button>
              <div class="flex justify-between text-sm">
                <button
                  type="button"
                  id="resend-code"
                  phx-click="resend"
                  class="cursor-pointer text-fg-muted hover:text-fg"
                >
                  {gettext("Send a new code")}
                </button>
                <button
                  type="button"
                  phx-click="change_email"
                  class="cursor-pointer text-fg-muted hover:text-fg"
                >
                  {gettext("Use another email")}
                </button>
              </div>
            </.form>
            <.access_form :if={@grant_token} slug={@link.slug} token={@grant_token} />
          </.public_card>
        <% :reading -> %>
          <header class="sticky top-0 z-20 flex h-(--topbar-height) items-center gap-3 border-b border-border bg-canvas/85 px-4 backdrop-blur-md">
            <span class="flex min-w-0 items-center gap-2">
              <Layouts.logo class="size-5 shrink-0" />
              <span class="hidden text-sm font-medium text-fg-muted sm:inline">{@workspace.name}</span>
              <.icon name="hero-chevron-right-micro" class="hidden size-3.5 text-fg-faint sm:inline" />
              <span class="truncate text-sm font-medium text-fg">{@link.document.title}</span>
            </span>
            <div class="ml-auto flex items-center gap-1.5">
              <.button
                :if={@link.allow_download and @visit_token}
                id="download-pdf"
                size="sm"
                icon="hero-arrow-down-tray-mini"
                href={~p"/v/#{@link.slug}/download/#{@visit_token}/pdf"}
              >
                {gettext("Download")}
              </.button>
              <.button
                :if={@link.allow_original_download and @visit_token and Version.office?(@version)}
                id="download-original"
                size="sm"
                variant="ghost"
                href={~p"/v/#{@link.slug}/download/#{@visit_token}/original"}
              >
                {gettext("Original")}
              </.button>
              <Layouts.theme_toggle id="viewer-theme" />
            </div>
          </header>
          <main class="px-3 py-6 sm:px-6">
            <%= if @visit_token do %>
              <.viewer
                id="viewer"
                pages={@streams.pages}
                thumbs={@streams.thumbs}
                page_count={@version.page_count}
                src={&~p"/v/#{@link.slug}/p/#{@visit_token}/#{&1.number}/#{Pdf.view_width()}"}
                thumb_src={&~p"/v/#{@link.slug}/p/#{@visit_token}/#{&1.number}/#{Pdf.thumb_width()}"}
                watermark={@watermark}
                track
              />
            <% else %>
              <%!-- Dead render: pages load once the live connection starts the visit. --%>
              <div id="viewer-loading" class="mx-auto max-w-3xl space-y-4">
                <.skeleton :for={_ <- 1..2} class="aspect-[1/1.414] w-full rounded-md" />
              </div>
            <% end %>
          </main>
      <% end %>
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :workspace, :any, required: true
  slot :inner_block, required: true

  defp public_card(assigns) do
    ~H"""
    <div class="relative flex min-h-dvh flex-col items-center justify-center px-4 py-12">
      <div
        class="pointer-events-none absolute inset-x-0 top-0 h-72 bg-[radial-gradient(60%_100%_at_50%_0%,var(--color-accent-soft),transparent)] opacity-70"
        aria-hidden="true"
      />
      <div class="relative w-full max-w-sm animate-fade-in">
        <div class="mb-8 flex items-center justify-center gap-2.5">
          <Layouts.logo class="size-7" />
          <span class="text-lg font-semibold tracking-tight text-fg">{@workspace.name}</span>
        </div>
        <div class="rounded-xl border border-border bg-surface p-6 shadow-md sm:p-8">
          {render_slot(@inner_block)}
        </div>
        <p class="mt-6 text-center text-xs text-fg-subtle">
          {gettext("Shared securely with Readout")}
        </p>
      </div>
    </div>
    """
  end

  attr :link, :any, required: true
  attr :workspace, :any, required: true

  defp doc_heading(assigns) do
    ~H"""
    <div class="mb-6">
      <p class="text-xs font-medium text-fg-subtle">
        {gettext("%{workspace} shared a document with you", workspace: @workspace.name)}
      </p>
      <h1 class="mt-1 text-xl font-semibold text-fg">{@link.document.title}</h1>
    </div>
    """
  end

  attr :slug, :string, required: true
  attr :token, :string, required: true

  # Posts the signed grant to the session controller as soon as it renders.
  defp access_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="access-form"
      action={~p"/v/#{@slug}/access"}
      phx-trigger-action
      class="hidden"
    >
      <input type="hidden" name="grant" value={@token} />
    </.form>
    """
  end

  ## Mount

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
    socket =
      socket
      |> assign(:workspace, Readout.Workspace.get_settings())
      |> assign(:page_title, gettext("Shared document"))
      |> assign(gate_error: nil, grant_token: nil, visit: nil, visit_token: nil)
      |> assign(:client_key, client_key(socket))

    case Links.fetch_public_link(slug) do
      {:ok, link} ->
        {:ok,
         socket
         |> assign(:link, link)
         |> assign(:page_title, link.document.title)
         |> assign(:known_email, known_email(session, link))
         |> enter(ViewerAccess.grant(session, link))}

      {:error, reason} ->
        {:ok, assign(socket, state: :unavailable, reason: reason)}
    end
  end

  # A verified email remembered on this device (only meaningful for links
  # that verify emails, and only if it is still allowed).
  defp known_email(session, %Link{require_verification: true} = link) do
    case session["verified:" <> link.slug] do
      email when is_binary(email) -> if Link.allows_email?(link, email), do: email
      _ -> nil
    end
  end

  defp known_email(_session, _link), do: nil

  # Already granted, or nothing to ask: read. Otherwise: the gate.
  defp enter(socket, %{"email" => email, "verified" => verified?}),
    do: start_reading(socket, email, verified?)

  defp enter(%{assigns: %{link: link}} = socket, nil) do
    if not link.require_email and not Link.password?(link) do
      start_reading(socket, nil, false)
    else
      socket
      |> assign(:state, :gate)
      |> assign(
        :gate_form,
        to_form(%{"email" => socket.assigns.known_email || "", "password" => ""}, as: "gate")
      )
    end
  end

  defp start_reading(socket, email, verified?) do
    socket =
      socket
      |> assign(state: :reading, email: email, verified: verified?)
      |> assign(:version, socket.assigns.link.document.current_version)
      |> assign(:watermark, watermark(socket.assigns.link, email))
      |> stream_configure(:pages, dom_id: &"page-#{&1.number}")
      |> stream_configure(:thumbs, dom_id: &"thumb-#{&1.number}")

    if connected?(socket) do
      link = socket.assigns.link

      visit =
        Links.start_visit(link, %{
          email: email,
          email_verified: verified?,
          ip: ClientIP.from_socket(socket),
          user_agent: get_connect_info(socket, :user_agent)
        })

      pages = Documents.list_pages(socket.assigns.version)

      socket
      |> assign(visit: visit, visit_token: ViewerAccess.sign_visit(visit.id))
      |> stream(:pages, pages)
      |> stream(:thumbs, pages)
    else
      socket |> stream(:pages, []) |> stream(:thumbs, [])
    end
  end

  defp watermark(%Link{watermark: true}, email) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")
    Enum.join(Enum.reject([email, stamp], &is_nil/1), " · ")
  end

  defp watermark(_link, _email), do: nil

  defp client_key(socket) do
    if connected?(socket), do: ClientIP.from_socket(socket) || "unknown", else: "dead"
  end

  ## Gate

  @impl true
  def handle_event("gate", %{"gate" => params}, %{assigns: %{state: :gate, link: link}} = socket) do
    params =
      if socket.assigns.known_email,
        do: Map.put(params, "email", socket.assigns.known_email),
        else: params

    case Links.check_gate(link, params, socket.assigns.client_key) do
      {:ok, email} ->
        cond do
          not link.require_verification ->
            {:noreply, grant(socket, email, false)}

          socket.assigns.known_email == email ->
            {:noreply, grant(socket, email, true)}

          not Readout.Mailer.enabled?() ->
            {:noreply,
             assign(
               socket,
               :gate_error,
               gettext("Email verification isn't available right now. Please contact the sender.")
             )}

          true ->
            send_code(socket, email)
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:gate_error, gate_error(reason))
         |> assign(:gate_form, to_form(Map.put(params, "password", ""), as: "gate"))}
    end
  end

  def handle_event("verify", %{"code" => code}, %{assigns: %{state: :code}} = socket) do
    %{link: link, email: email} = socket.assigns

    with :ok <-
           Readout.RateLimit.hit(
             {:verify, link.id, socket.assigns.client_key},
             20,
             :timer.minutes(10)
           ),
         :ok <- Links.verify_code(link, email, code) do
      {:noreply, grant(socket, email, true)}
    else
      {:error, reason} -> {:noreply, assign(socket, :gate_error, gate_error(reason))}
    end
  end

  def handle_event("resend", _params, %{assigns: %{state: :code}} = socket) do
    send_code(socket, socket.assigns.email)
  end

  def handle_event("change_email", _params, socket) do
    {:noreply,
     socket
     |> assign(state: :gate, gate_error: nil, known_email: nil)
     |> assign(:gate_form, to_form(%{"email" => "", "password" => ""}, as: "gate"))}
  end

  ## Reading (page tracking arrives with analytics)

  def handle_event("page", %{"page" => _page}, socket), do: {:noreply, socket}
  def handle_event("visibility", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp send_code(socket, email) do
    case Links.send_verification(
           socket.assigns.link,
           email,
           socket.assigns.locale,
           socket.assigns.client_key
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(state: :code, email: email, gate_error: nil)
         |> assign(:code_form, to_form(%{}, as: "code"))}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, :gate_error, gate_error(:rate_limited))}
    end
  end

  # Hand the signed grant to the session controller (it sets the session and,
  # for verified emails, the device cookie), which redirects back here.
  defp grant(socket, email, verified?) do
    assign(socket,
      grant_token: ViewerAccess.sign_grant(socket.assigns.link, email, verified?),
      gate_error: nil
    )
  end

  @impl true
  def terminate(_reason, %{assigns: %{visit: %{} = visit}}), do: Links.end_visit(visit)
  def terminate(_reason, _socket), do: :ok

  ## Copy

  defp gate_error(:wrong_password), do: gettext("That password isn't right.")
  defp gate_error(:invalid_email), do: gettext("Please enter a valid email address.")
  defp gate_error(:email_not_allowed), do: gettext("This email can't open this document.")

  defp gate_error(:rate_limited),
    do: gettext("Too many attempts. Please wait a few minutes and try again.")

  defp gate_error(:wrong_code), do: gettext("That code isn't right.")
  defp gate_error(:expired), do: gettext("That code has expired. Send a new one.")
  defp gate_error(:too_many_attempts), do: gettext("Too many wrong codes. Send a new one.")

  defp unavailable_icon(:expired), do: "hero-clock"
  defp unavailable_icon(:not_ready), do: "hero-arrow-path"
  defp unavailable_icon(_), do: "hero-link-slash"

  defp unavailable_title(:expired), do: gettext("This link has expired")
  defp unavailable_title(:not_ready), do: gettext("This document is almost ready")
  defp unavailable_title(_), do: gettext("This link isn't available")

  defp unavailable_text(:not_ready),
    do: gettext("It's being prepared. Please try again in a minute.")

  defp unavailable_text(_), do: gettext("Ask the person who shared it for a new link.")
end
