defmodule ReadoutWeb.PageController do
  use ReadoutWeb, :controller

  alias Readout.Accounts.Scope

  @doc "The root sends people where they belong: the app, sign-in, or first-run setup."
  def home(conn, _params) do
    cond do
      match?(%Scope{user: %{}}, conn.assigns.current_scope) ->
        redirect(conn, to: ~p"/documents")

      not Readout.Accounts.any_users?() ->
        redirect(conn, to: ~p"/setup")

      true ->
        redirect(conn, to: ~p"/users/log-in")
    end
  end

  def settings(conn, _params), do: redirect(conn, to: ~p"/settings/profile")
end
