defmodule Readout.Accounts.Scope do
  @moduledoc """
  The caller of an operation: the signed-in user plus their resolved locale and
  time zone.

  Every context function that acts on behalf of someone takes the scope as its
  first argument and checks it with `Readout.Policy`. The locale and time zone
  ride along so formatting helpers can take the scope too.
  """

  alias Readout.Accounts.User

  defstruct user: nil, locale: "en", timezone: "Etc/UTC"

  @type t :: %__MODULE__{user: User.t() | nil, locale: String.t(), timezone: String.t()}

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user, timezone: user.timezone || "Etc/UTC"}
  end

  def for_user(nil), do: nil

  @doc "Sets the resolved UI locale."
  def put_locale(%__MODULE__{} = scope, locale), do: %{scope | locale: locale}
  def put_locale(nil, _locale), do: nil

  @doc """
  Sets the browser time zone, unless the user's profile overrides it.
  """
  def put_browser_timezone(%__MODULE__{user: %User{timezone: tz}} = scope, _browser_tz)
      when is_binary(tz),
      do: scope

  def put_browser_timezone(%__MODULE__{} = scope, browser_tz) do
    if Readout.TimeZones.valid?(browser_tz), do: %{scope | timezone: browser_tz}, else: scope
  end

  def put_browser_timezone(nil, _), do: nil

  @doc "The role of the scope's user, or nil."
  def role(%__MODULE__{user: %User{role: role}}), do: role
  def role(_), do: nil
end
