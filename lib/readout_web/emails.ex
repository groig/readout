defmodule ReadoutWeb.Emails do
  @moduledoc """
  Every email Readout sends: invitations, sign-in links, password resets,
  email-change confirmations and viewer verification codes.

  Each one is translated (the recipient's locale) and has a simple HTML
  version styled like the app, plus a plain-text version. Interpolated values
  are always HTML-escaped.
  """
  use Gettext, backend: ReadoutWeb.Gettext

  import Swoosh.Email

  @accent "#4150b8"

  @doc "An invitation to join the workspace."
  def invitation(to, locale, %{
        url: url,
        inviter: inviter,
        role: role,
        workspace: ws,
        expires_on: date
      }) do
    with_locale(locale, fn ->
      subject =
        gettext("%{name} invited you to %{workspace} on Readout", name: inviter, workspace: ws)

      lead =
        gettext("%{name} invited you to join %{workspace} on Readout as %{role}.",
          name: inviter,
          workspace: ws,
          role: role
        )

      build(to, subject,
        heading: gettext("You're invited"),
        paragraphs: [
          lead,
          gettext("The link expires on %{date}.", date: ReadoutWeb.Format.date(date, "Etc/UTC"))
        ],
        button: {gettext("Accept the invitation"), url}
      )
    end)
  end

  @doc "A one-time sign-in link."
  def login(to, locale, %{url: url, name: name}) do
    with_locale(locale, fn ->
      build(to, gettext("Your Readout sign-in link"),
        heading: gettext("Hi %{name},", name: name),
        paragraphs: [
          gettext(
            "Use the button below to sign in. The link works once and expires in 15 minutes."
          )
        ],
        button: {gettext("Sign in to Readout"), url},
        footnote: gettext("If you didn't ask for this, you can ignore this email.")
      )
    end)
  end

  @doc "A password reset link."
  def reset_password(to, locale, %{url: url, name: name}) do
    with_locale(locale, fn ->
      build(to, gettext("Reset your Readout password"),
        heading: gettext("Hi %{name},", name: name),
        paragraphs: [
          gettext("Choose a new password with the button below. The link expires in one hour.")
        ],
        button: {gettext("Choose a new password"), url},
        footnote:
          gettext(
            "If you didn't ask for this, you can ignore this email. Your password won't change."
          )
      )
    end)
  end

  @doc "Confirmation for a new email address."
  def update_email(to, locale, %{url: url}) do
    with_locale(locale, fn ->
      build(to, gettext("Confirm your new email address"),
        heading: gettext("Confirm your new email"),
        paragraphs: [gettext("Confirm that this is your new email address for Readout.")],
        button: {gettext("Confirm email address"), url},
        footnote: gettext("If you didn't ask for this, you can ignore this email.")
      )
    end)
  end

  @doc "A 6-digit code for a link with email verification."
  def verification_code(to, locale, %{
        code: code,
        document: title,
        workspace: ws,
        minutes: minutes
      }) do
    with_locale(locale, fn ->
      build(to, gettext("%{code} is your code to view “%{title}”", code: code, title: title),
        heading: gettext("Your verification code"),
        paragraphs: [
          gettext("%{workspace} shared “%{title}” with you. Enter this code to open it:",
            workspace: ws,
            title: title
          )
        ],
        code: code,
        footnote:
          gettext(
            "The code expires in %{minutes} minutes. If you didn't ask for it, ignore this email.",
            minutes: minutes
          )
      )
    end)
  end

  ## Building

  defp with_locale(locale, fun) when locale in ["en", "es"],
    do: Gettext.with_locale(ReadoutWeb.Gettext, locale, fun)

  defp with_locale(_locale, fun), do: Gettext.with_locale(ReadoutWeb.Gettext, "en", fun)

  defp build(to, subject, parts) do
    new()
    |> to(to)
    |> from(Readout.Mailer.from())
    |> subject(subject)
    |> html_body(html(subject, parts))
    |> text_body(text(parts))
  end

  defp text(parts) do
    [
      parts[:heading],
      "",
      Enum.join(parts[:paragraphs] || [], "\n\n"),
      parts[:code] && "\n    #{parts[:code]}\n",
      case parts[:button] do
        {label, url} -> "\n#{label}:\n#{url}\n"
        nil -> nil
      end,
      parts[:footnote] && "\n#{parts[:footnote]}",
      "\n--\nReadout"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp html(subject, parts) do
    paragraphs =
      for p <- parts[:paragraphs] || [],
          do:
            ~s(<p style="margin:0 0 14px;font-size:15px;line-height:22px;color:#3d3a36">#{esc(p)}</p>)

    code =
      if c = parts[:code] do
        ~s(<p style="margin:18px 0 22px;font-family:'JetBrains Mono',Menlo,Consolas,monospace;font-size:32px;letter-spacing:8px;font-weight:600;color:#1f1d1a">#{esc(c)}</p>)
      end

    button =
      case parts[:button] do
        {label, url} ->
          ~s(<p style="margin:22px 0 6px"><a href="#{esc(url)}" style="display:inline-block;background:#{@accent};color:#ffffff;text-decoration:none;font-weight:600;font-size:15px;padding:11px 20px;border-radius:8px">#{esc(label)}</a></p>
             <p style="margin:12px 0 0;font-size:12px;line-height:18px;color:#8a857e;word-break:break-all">#{esc(url)}</p>)

        nil ->
          nil
      end

    footnote =
      if f = parts[:footnote],
        do:
          ~s(<p style="margin:22px 0 0;font-size:13px;line-height:19px;color:#8a857e">#{esc(f)}</p>)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>#{esc(subject)}</title></head>
    <body style="margin:0;padding:0;background:#f7f6f4;font-family:Inter,-apple-system,'Segoe UI',Helvetica,Arial,sans-serif">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f7f6f4;padding:32px 16px">
        <tr><td align="center">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px">
            <tr><td style="padding:0 4px 16px;font-size:16px;font-weight:600;color:#1f1d1a">
              <span style="display:inline-block;width:20px;height:20px;border-radius:5px;background:#{@accent};vertical-align:-4px;margin-right:8px"></span>Readout
            </td></tr>
            <tr><td style="background:#ffffff;border:1px solid #e8e6e2;border-radius:12px;padding:28px">
              <h1 style="margin:0 0 14px;font-size:20px;line-height:28px;color:#1f1d1a">#{esc(parts[:heading])}</h1>
              #{Enum.join(paragraphs)}
              #{code}
              #{button}
              #{footnote}
            </td></tr>
          </table>
        </td></tr>
      </table>
    </body></html>
    """
  end

  defp esc(nil), do: ""
  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
