defmodule Readout.AuditTest do
  use Readout.DataCase, async: true

  import Readout.AccountsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Audit

  setup do
    owner = owner_fixture(name: "Alex")
    %{owner: owner, scope: Scope.for_user(owner)}
  end

  test "log/4 records who, what and when, with readable labels", %{owner: owner, scope: scope} do
    target = user_fixture(email: "mia@example.com")
    event = Audit.log(scope, "user.deactivated", target, %{reason: :test})

    assert event.actor_id == owner.id
    assert event.actor_name == "Alex"
    assert event.subject_type == "user"
    assert event.subject_label == "mia@example.com"
    assert event.metadata == %{"reason" => "test"}
    assert event.inserted_at
  end

  test "only owners and admins can read the log", %{scope: scope} do
    Audit.log(scope, "workspace.updated")
    assert {:ok, [_]} = Audit.list_events(scope)
    assert {:ok, _} = Audit.list_events(Scope.for_user(admin_fixture()))
    assert {:error, :unauthorized} = Audit.list_events(Scope.for_user(user_fixture()))
    assert {:error, :unauthorized} = Audit.list_events(Scope.for_user(observer_fixture()))
  end

  test "filters by category, actor and text, newest first", %{scope: scope} do
    other = admin_fixture(name: "Adam")
    Audit.log(scope, "invitation.created", %{email: "a@x.com"})
    Audit.log(other, "user.role_changed", user_fixture(email: "z@x.com"))

    assert {:ok, [%{action: "invitation.created"}]} =
             Audit.list_events(scope, action: "invitation.")

    assert {:ok, [%{action: "user.role_changed"}]} = Audit.list_events(scope, actor_id: other.id)
    assert {:ok, [%{action: "user.role_changed"}]} = Audit.list_events(scope, query: "z@x")
    assert {:ok, [%{action: "user.role_changed"}, _]} = Audit.list_events(scope)
  end

  test "search escapes LIKE wildcards", %{scope: scope} do
    Audit.log(scope, "invitation.created", %{email: "plain@x.com"})
    assert {:ok, []} = Audit.list_events(scope, query: "%")
    assert {:ok, []} = Audit.list_events(scope, query: "_")
  end

  test "paginates with a cursor", %{scope: scope} do
    for _ <- 1..3, do: Audit.log(scope, "workspace.updated")
    {:ok, [first, second]} = Audit.list_events(scope, limit: 2)
    {:ok, [third]} = Audit.list_events(scope, before: second.inserted_at)
    assert DateTime.compare(first.inserted_at, third.inserted_at) == :gt
  end

  test "broadcasts new events to subscribers", %{scope: scope} do
    :ok = Audit.subscribe(scope)
    Audit.log(scope, "workspace.updated")
    assert_receive {:audit_event, %{action: "workspace.updated"}}
  end
end
