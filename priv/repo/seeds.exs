# Development seed data: a small team, so every screen has something to show.
#
#     mix run priv/repo/seeds.exs
#
# Sign in as owner@readout.test with the password below. Safe to re-run: it
# does nothing once any account exists.

alias Readout.Accounts
alias Readout.Accounts.Scope

password = "readout-dev-password"

if Accounts.any_users?() do
  IO.puts("Seeds skipped: accounts already exist.")
else
  {:ok, owner} =
    Accounts.bootstrap_owner(%{
      "name" => "Alex Morgan",
      "email" => "owner@readout.test",
      "password" => password
    })

  owner_scope = Scope.for_user(owner)

  people = [
    {"Adrián Admin", "admin@readout.test", :admin},
    {"Marta Member", "member@readout.test", :member},
    {"Óscar Observer", "observer@readout.test", :observer}
  ]

  for {name, email, role} <- people do
    {:ok, {_invitation, token}} =
      Accounts.create_invitation(owner_scope, %{"email" => email, "role" => role})

    {:ok, _user} = Accounts.accept_invitation(token, %{"name" => name, "password" => password})
  end

  {:ok, _} =
    Accounts.create_invitation(owner_scope, %{
      "email" => "pending@client.example",
      "role" => "member"
    })

  IO.puts("""
  Seeded. Sign in with any of these (password: #{password}):
    owner@readout.test  admin@readout.test  member@readout.test  observer@readout.test
  """)
end
