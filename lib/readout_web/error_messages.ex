defmodule ReadoutWeb.ErrorMessages do
  @moduledoc """
  Changeset messages written in our schemas. Listed here with
  `dgettext_noop/2` so `mix gettext.extract` puts them in the "errors" domain;
  `ReadoutWeb.CoreComponents.translate_error/1` translates them at render time.
  """
  use Gettext, backend: ReadoutWeb.Gettext

  @doc false
  def messages do
    [
      dgettext_noop("errors", "must have the @ sign and no spaces"),
      dgettext_noop("errors", "did not change"),
      dgettext_noop("errors", "does not match password"),
      dgettext_noop("errors", "is not a valid time zone"),
      dgettext_noop("errors", "is already a member"),
      dgettext_noop("errors", "already has a pending invitation"),
      dgettext_noop("errors", "must have the @ sign")
    ]
  end
end
