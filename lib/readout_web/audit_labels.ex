defmodule ReadoutWeb.AuditLabels do
  @moduledoc "Human, translated sentences and icons for audit log entries."
  use Gettext, backend: ReadoutWeb.Gettext

  alias Readout.Accounts.User
  alias Readout.Audit.Event

  @doc "Filter categories: {label, action prefix}."
  def categories do
    [
      {gettext("Invitations"), "invitation."},
      {gettext("Members"), "user."},
      {gettext("Workspace"), "workspace."}
    ]
  end

  @doc "A sentence describing the event."
  def describe(%Event{} = event) do
    actor = event.actor_name || gettext("Someone")
    subject = event.subject_label || gettext("someone")
    meta = event.metadata || %{}

    case event.action do
      "workspace.created" ->
        gettext("%{actor} set up the workspace", actor: actor)

      "workspace.updated" ->
        gettext("%{actor} updated the workspace settings", actor: actor)

      "workspace.ownership_transferred" ->
        gettext("%{actor} transferred ownership to %{subject}", actor: actor, subject: subject)

      "invitation.created" ->
        gettext("%{actor} invited %{subject} as %{role}",
          actor: actor,
          subject: subject,
          role: role(meta["role"])
        )

      "invitation.resent" ->
        gettext("%{actor} sent a new invitation link to %{subject}",
          actor: actor,
          subject: subject
        )

      "invitation.revoked" ->
        gettext("%{actor} revoked the invitation for %{subject}", actor: actor, subject: subject)

      "invitation.accepted" ->
        gettext("%{actor} joined as %{role}", actor: actor, role: role(meta["role"]))

      "user.role_changed" ->
        gettext("%{actor} changed %{subject} from %{from} to %{to}",
          actor: actor,
          subject: subject,
          from: role(meta["from"]),
          to: role(meta["to"])
        )

      "user.deactivated" ->
        gettext("%{actor} deactivated %{subject}", actor: actor, subject: subject)

      "user.reactivated" ->
        gettext("%{actor} reactivated %{subject}", actor: actor, subject: subject)

      other ->
        "#{actor} · #{other}"
    end
  end

  @doc "An icon for the event's category."
  def icon(%Event{action: action}) do
    case action do
      "invitation." <> _ -> "hero-envelope"
      "user.deactivated" -> "hero-no-symbol"
      "user." <> _ -> "hero-user"
      "workspace." <> _ -> "hero-building-office-2"
      "link." <> _ -> "hero-link"
      "document.downloaded" -> "hero-arrow-down-tray"
      "document." <> _ -> "hero-document-text"
      _ -> "hero-bolt"
    end
  end

  defp role(nil), do: "?"

  defp role(role) when is_binary(role) do
    case Enum.find(User.roles(), &(Atom.to_string(&1) == role)) do
      nil -> role
      atom -> ReadoutWeb.Layouts.role_label(atom)
    end
  end
end
