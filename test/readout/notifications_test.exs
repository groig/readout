defmodule Readout.NotificationsTest do
  use Readout.DataCase, async: true

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Links, Notifications, Repo}
  alias Readout.Notifications.RocketChatJob

  setup do
    owner = user_fixture(name: "Alex", chat_username: "alex")
    scope = Scope.for_user(owner)
    {doc, link} = shared_fixture(scope)
    %{owner: owner, scope: scope, doc: doc, link: link}
  end

  test "you follow your own documents by default, and can mute them", %{scope: scope, doc: doc} do
    assert Notifications.subscribed?(scope, doc)
    {:ok, _} = Notifications.set_subscription(scope, doc, false)
    refute Notifications.subscribed?(scope, doc)
  end

  test "the profile switch turns the default off", %{doc: doc} do
    quiet = user_fixture()

    {:ok, quiet} =
      Readout.Accounts.update_profile(Scope.for_user(quiet), %{"notifications_enabled" => "false"})

    refute Notifications.subscribed?(Scope.for_user(quiet), doc)
  end

  test "followers can see the document and are active", %{scope: scope, owner: owner, doc: doc} do
    colleague = user_fixture()
    {:ok, _} = Notifications.set_subscription(Scope.for_user(colleague), doc, true)

    assert doc |> Notifications.followers() |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([owner.id, colleague.id])

    {:ok, _} = Documents.update_visibility(scope, doc, :restricted)
    doc = Documents.get_document(scope, doc.id)
    assert Enum.map(Notifications.followers(doc), & &1.id) == [owner.id]
  end

  test "messages: who opened what via which link, then a summary", %{owner: owner, link: link} do
    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit(link, %{email: "ana@client.com", email_verified: true})
    visit = Readout.Analytics.record(visit, %{1 => 30_000, 2 => 90_000}, %{1 => 1, 2 => 1}, 2)
    visit = Repo.preload(visit, [:link, :page_views, document: :members], force: true)

    opened = RocketChatJob.message("opened", visit, [owner])

    assert opened =~
             "ana@client.com (verified) opened «#{visit.document.title}» via the «Client X» link"

    assert opened =~ "@alex"
    assert opened =~ "/documents/#{visit.document_id}/analytics?visit=#{visit.id}"

    finished = RocketChatJob.message("finished", visit, [owner])
    assert finished =~ "2 of 3 pages in 2m 00s, most time on page 2"
  end

  test "messages use the workspace notification language", %{
    scope: scope,
    owner: owner,
    link: link
  } do
    {:ok, _} =
      Readout.Workspace.update_settings(Scope.for_user(owner_fixture()), %{
        "notification_locale" => "es"
      })

    _ = scope
    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit(link, %{}) |> Repo.preload([:link, :page_views, document: :members])
    assert RocketChatJob.message("opened", visit, [owner]) =~ "Un lector anónimo abrió"
  end

  test "an empty visit sends no summary", %{owner: owner, link: link} do
    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit(link, %{}) |> Repo.preload([:link, :page_views, document: :members])
    assert RocketChatJob.message("finished", visit, [owner]) == nil
  end
end
