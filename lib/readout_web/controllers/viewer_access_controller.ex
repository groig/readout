defmodule ReadoutWeb.ViewerAccessController do
  @moduledoc """
  Turns a passed gate into a session grant (and, for verified emails, a
  30-day device cookie). The gate LiveView posts here with a short-lived
  signed token; nothing from the form itself is trusted.
  """
  use ReadoutWeb, :controller

  alias Readout.Links
  alias ReadoutWeb.ViewerAccess

  def create(conn, %{"slug" => slug, "grant" => token}) do
    with {:ok, link} <- Links.fetch_public_link(slug),
         {:ok, %{"link_id" => link_id, "email" => email, "verified" => verified?}} <-
           ViewerAccess.verify_grant(token),
         true <- link_id == link.id do
      conn
      |> ViewerAccess.put_grant(link.id, email, verified?)
      |> then(
        &if(verified? and email, do: ViewerAccess.remember_verified(&1, slug, email), else: &1)
      )
      |> redirect(to: ~p"/v/#{slug}")
    else
      _ -> redirect(conn, to: ~p"/v/#{slug}")
    end
  end

  def create(conn, %{"slug" => slug}), do: redirect(conn, to: ~p"/v/#{slug}")
end
