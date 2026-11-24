defmodule Readout.PolicyTest do
  @moduledoc "The authorization matrix: every role × every action."
  use ExUnit.Case, async: true

  alias Readout.Accounts.{Scope, User}
  alias Readout.Policy

  @roles [:owner, :admin, :member, :observer]

  defp scope(role, attrs \\ []) do
    Scope.for_user(struct(%User{id: Ecto.UUID.generate(), role: role}, attrs))
  end

  defp user(role), do: %User{id: Ecto.UUID.generate(), role: role}

  # action => roles allowed
  @workspace_matrix %{
    view_members: [:owner, :admin, :member, :observer],
    manage_members: [:owner, :admin],
    invite: [:owner, :admin],
    view_audit_log: [:owner, :admin],
    manage_workspace: [:owner],
    transfer_ownership: [:owner],
    upload_document: [:owner, :admin, :member],
    view_analytics: [:owner, :admin, :member, :observer]
  }

  describe "workspace actions" do
    for {action, allowed} <- @workspace_matrix, role <- @roles do
      expected = role in allowed

      test "#{role} #{if expected, do: "can", else: "cannot"} #{action}" do
        assert Policy.can?(scope(unquote(role)), unquote(action), :workspace) == unquote(expected)
      end
    end
  end

  # actor role => roles it may grant
  @assign_matrix %{
    owner: [:owner, :admin, :member, :observer],
    admin: [:admin, :member, :observer],
    member: [],
    observer: []
  }

  describe "assigning roles" do
    for {actor, grantable} <- @assign_matrix, role <- @roles do
      expected = role in grantable

      test "#{actor} #{if expected, do: "can", else: "cannot"} grant #{role}" do
        assert Policy.can?(scope(unquote(actor)), :assign_role, unquote(role)) ==
                 unquote(expected)
      end
    end
  end

  # actor role => target roles it may change, deactivate or reactivate
  @manage_matrix %{
    owner: [:owner, :admin, :member, :observer],
    admin: [:member, :observer],
    member: [],
    observer: []
  }

  describe "acting on other people" do
    for action <- [:change_role, :deactivate, :reactivate],
        {actor, targets} <- @manage_matrix,
        target <- @roles do
      expected = target in targets

      test "#{actor} #{if expected, do: "can", else: "cannot"} #{action} a #{target}" do
        assert Policy.can?(scope(unquote(actor)), unquote(action), user(unquote(target))) ==
                 unquote(expected)
      end
    end

    test "nobody acts on themselves" do
      for role <- @roles, action <- [:change_role, :deactivate, :reactivate] do
        %Scope{user: me} = actor = scope(role)
        refute Policy.can?(actor, action, me), "#{role} could #{action} themselves"
      end
    end
  end

  describe "documents" do
    alias Readout.Documents.{Document, Member}

    defp doc(owner_id, visibility, members \\ []) do
      %Document{
        id: Ecto.UUID.generate(),
        owner_id: owner_id,
        visibility: visibility,
        members:
          Enum.map(members, fn {user_id, role} -> %Member{user_id: user_id, role: role} end)
      }
    end

    test "workspace documents: everyone views; only owner and admins change them" do
      for role <- @roles do
        actor = scope(role)
        d = doc(Ecto.UUID.generate(), :workspace)
        assert Policy.can?(actor, :view_document, d)
        assert Policy.can?(actor, :edit_document, d) == role in [:owner, :admin]
        assert Policy.can?(actor, :manage_document, d) == role in [:owner, :admin]
      end
    end

    test "restricted documents: only owner, people added and admins view them" do
      for role <- @roles do
        actor = scope(role)
        d = doc(Ecto.UUID.generate(), :restricted)
        assert Policy.can?(actor, :view_document, d) == role in [:owner, :admin]
      end
    end

    test "document owners manage their documents unless they're observers" do
      for role <- @roles do
        %Scope{user: me} = actor = scope(role)
        d = doc(me.id, :restricted)
        assert Policy.can?(actor, :view_document, d)
        assert Policy.can?(actor, :edit_document, d) == (role != :observer)
        assert Policy.can?(actor, :manage_document, d) == (role != :observer)
      end
    end

    test "editors edit, viewers view, neither manages" do
      %Scope{user: me} = actor = scope(:member)

      editor_doc = doc(Ecto.UUID.generate(), :restricted, [{me.id, :editor}])
      assert Policy.can?(actor, :view_document, editor_doc)
      assert Policy.can?(actor, :edit_document, editor_doc)
      refute Policy.can?(actor, :manage_document, editor_doc)

      viewer_doc = doc(Ecto.UUID.generate(), :restricted, [{me.id, :viewer}])
      assert Policy.can?(actor, :view_document, viewer_doc)
      refute Policy.can?(actor, :edit_document, viewer_doc)

      %Scope{user: obs} = observer = scope(:observer)
      observer_editor = doc(Ecto.UUID.generate(), :restricted, [{obs.id, :editor}])
      assert Policy.can?(observer, :view_document, observer_editor)
      refute Policy.can?(observer, :edit_document, observer_editor)
    end

    test "members must be preloaded" do
      assert_raise ArgumentError, fn ->
        Policy.can?(scope(:member), :view_document, %Document{
          visibility: :restricted,
          owner_id: "x"
        })
      end
    end
  end

  describe "edge cases" do
    test "a deactivated user can do nothing" do
      actor = scope(:owner, deactivated_at: DateTime.utc_now())

      for {action, _} <- @workspace_matrix do
        refute Policy.can?(actor, action, :workspace)
      end

      refute Policy.can?(actor, :change_role, user(:member))
    end

    test "no scope can do nothing" do
      refute Policy.can?(nil, :view_members, :workspace)
      refute Policy.can?(%Scope{}, :view_members, :workspace)
    end

    test "unknown actions are denied" do
      refute Policy.can?(scope(:owner), :launch_rockets, :workspace)
      refute Policy.can?(scope(:owner), :assign_role, :superuser)
    end

    test "authorize/3 returns ok or an error tuple" do
      assert Policy.authorize(scope(:owner), :manage_workspace, :workspace) == :ok

      assert Policy.authorize(scope(:member), :manage_workspace, :workspace) ==
               {:error, :unauthorized}
    end
  end
end
