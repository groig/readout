defmodule ReadoutWeb.UserSessionController do
  use ReadoutWeb, :controller

  alias Readout.{Accounts, RateLimit}
  alias ReadoutWeb.UserAuth

  def create(conn, %{"_action" => "setup"} = params) do
    create(conn, params, gettext("Welcome to Readout. Your workspace is ready."))
  end

  def create(conn, %{"_action" => "joined"} = params) do
    create(conn, params, gettext("Welcome aboard!"))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, gettext("That sign-in link is invalid or has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login. Throttled before bcrypt runs, per client and per
  # account (known or not, so the limit reveals nothing).
  defp create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}, info)
       when is_binary(email) and is_binary(password) do
    with :ok <- throttle(conn, email),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(
          :error,
          gettext("Too many attempts. Please wait a few minutes and try again.")
        )
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      nil ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, gettext("Invalid email or password"))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp create(conn, _params, _info) do
    conn
    |> put_flash(:error, gettext("Invalid email or password"))
    |> redirect(to: ~p"/users/log-in")
  end

  @window :timer.minutes(15)

  # Attempts per 15 minutes: per client IP (`ReadoutWeb.ClientIP`) and per
  # account. Configurable (`:login_limits`) so tests sharing 127.0.0.1 don't
  # trip the client limit.
  defp throttle(conn, email) do
    limits = Application.get_env(:readout, :login_limits, [])
    account = email |> String.trim() |> String.downcase() |> String.slice(0, 160)
    client = conn.remote_ip |> :inet.ntoa() |> to_string()

    with :ok <- RateLimit.hit({:login_client, client}, limits[:client] || 30, @window) do
      RateLimit.hit({:login_account, account}, limits[:account] || 10, @window)
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/settings/account")
    |> create(params, gettext("Password updated."))
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Signed out."))
    |> UserAuth.log_out_user()
  end
end
