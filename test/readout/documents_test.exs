defmodule Readout.DocumentsTest do
  use Readout.DataCase, async: true
  use Oban.Testing, repo: Readout.Repo

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Storage}
  alias Readout.Documents.{ProcessVersion, Version}

  setup do
    owner = user_fixture(name: "Doc Owner")
    %{owner: owner, scope: Scope.for_user(owner)}
  end

  describe "create_document/2" do
    test "stores the original, names it after the file and queues processing", %{
      scope: scope,
      owner: owner
    } do
      assert {:ok, doc} = Documents.create_document(scope, upload("sample.docx"))
      assert doc.title == "sample"
      assert doc.owner_id == owner.id
      assert doc.visibility == :workspace

      version = doc.latest_version
      assert version.number == 1
      assert version.format == :docx
      assert version.status == :pending
      assert String.length(version.checksum) == 64
      assert Storage.exists?(version.original_key)
      assert_enqueued(worker: ProcessVersion, args: %{version_id: version.id})
    end

    test "rejects files that aren't what they claim", %{scope: scope} do
      assert {:error, :unsupported} = Documents.create_document(scope, upload("fake.pdf"))
    end

    test "observers can't upload" do
      scope = Scope.for_user(observer_fixture())
      assert {:error, :unauthorized} = Documents.create_document(scope, upload("sample.pdf"))
    end
  end

  describe "versions" do
    test "new versions are numbered and become current once ready", %{scope: scope} do
      doc = document_fixture(scope)
      v1 = fake_ready!(doc)
      doc = Documents.get_document(scope, doc.id)
      assert doc.current_version_id == v1.id

      assert {:ok, v2} = Documents.add_version(scope, doc, upload("sample.pdf"))
      assert v2.number == 2

      # Links keep showing v1 until v2 is processed.
      assert Documents.get_document(scope, doc.id).current_version_id == v1.id
      fake_ready!(doc)
      assert Documents.get_document(scope, doc.id).current_version_id == v2.id
    end

    test "a failed version doesn't replace the current one and can be retried", %{scope: scope} do
      doc = document_fixture(scope)
      v1 = fake_ready!(doc)

      {:ok, v2} =
        Documents.add_version(scope, Documents.get_document(scope, doc.id), upload("sample.pdf"))

      v2 = Documents.fail_version(v2, "unreadable")

      doc = Documents.get_document(scope, doc.id)
      assert doc.current_version_id == v1.id
      assert doc.latest_version.status == :failed

      assert {:ok, %Version{status: :pending}} = Documents.retry_version(scope, doc, v2)
    end
  end

  describe "visibility and access" do
    setup %{scope: scope} do
      doc = document_fixture(scope)
      %{doc: Documents.get_document(scope, doc.id)}
    end

    test "workspace documents are visible to everyone", %{doc: doc} do
      other = Scope.for_user(observer_fixture())
      assert Documents.get_document(other, doc.id)
      assert [_] = Documents.list_documents(other)
    end

    test "restricted documents are visible to owner, members and admins only", %{
      scope: scope,
      doc: doc
    } do
      {:ok, _} = Documents.update_visibility(scope, doc, :restricted)

      stranger = Scope.for_user(user_fixture())
      refute Documents.get_document(stranger, doc.id)
      assert Documents.list_documents(stranger) == []

      assert Documents.get_document(Scope.for_user(admin_fixture()), doc.id)

      viewer = user_fixture()
      doc = Documents.get_document(scope, doc.id)
      {:ok, _} = Documents.put_member(scope, doc, viewer, :viewer)
      assert Documents.get_document(Scope.for_user(viewer), doc.id)
      assert [_] = Documents.list_documents(Scope.for_user(viewer))

      :ok = Documents.remove_member(scope, Documents.get_document(scope, doc.id), viewer.id)
      refute Documents.get_document(Scope.for_user(viewer), doc.id)
    end

    test "editors can rename and upload versions; viewers can't", %{scope: scope, doc: doc} do
      editor = user_fixture()
      viewer = user_fixture()
      {:ok, _} = Documents.put_member(scope, doc, editor, :editor)
      {:ok, _} = Documents.put_member(scope, doc, viewer, :viewer)

      as_editor = Documents.get_document(Scope.for_user(editor), doc.id)

      assert {:ok, %{title: "Renamed"}} =
               Documents.rename_document(Scope.for_user(editor), as_editor, %{
                 "title" => "Renamed"
               })

      assert {:error, :unauthorized} =
               Documents.update_visibility(Scope.for_user(editor), as_editor, :restricted)

      as_viewer = Documents.get_document(Scope.for_user(viewer), doc.id)

      assert {:error, :unauthorized} =
               Documents.rename_document(Scope.for_user(viewer), as_viewer, %{"title" => "x"})

      assert {:error, :unauthorized} =
               Documents.add_version(Scope.for_user(viewer), as_viewer, upload("sample.pdf"))
    end

    test "other members can see but not change workspace documents", %{doc: doc} do
      other = Scope.for_user(user_fixture())
      doc = Documents.get_document(other, doc.id)
      assert {:error, :unauthorized} = Documents.rename_document(other, doc, %{"title" => "x"})
      assert {:error, :unauthorized} = Documents.delete_document(other, doc)
    end

    test "deleting hides the document, removes its files and is audited", %{
      scope: scope,
      doc: doc
    } do
      key = doc.latest_version.original_key
      assert {:ok, _} = Documents.delete_document(scope, doc)
      refute Documents.get_document(scope, doc.id)
      assert Documents.list_documents(scope) == []
      refute Storage.exists?(key)
      assert Readout.Repo.get_by(Readout.Audit.Event, action: "document.deleted")
    end
  end

  describe "listing" do
    test "searches titles and sorts", %{scope: scope} do
      a = document_fixture(scope, "sample.pdf")

      {:ok, _} =
        Documents.rename_document(scope, Documents.get_document(scope, a.id), %{
          "title" => "Zeta proposal"
        })

      b = document_fixture(scope, "sample.docx")

      {:ok, _} =
        Documents.rename_document(scope, Documents.get_document(scope, b.id), %{
          "title" => "Alpha report"
        })

      assert [%{title: "Alpha report"}, %{title: "Zeta proposal"}] =
               Documents.list_documents(scope, sort: "title")

      assert [%{title: "Zeta proposal"}] = Documents.list_documents(scope, query: "zeta")
      assert [%{latest_version: %Version{}} | _] = Documents.list_documents(scope)
    end

    test "searches page text of the current version", %{scope: scope} do
      doc = document_fixture(scope)
      fake_ready!(doc, 3)
      assert [_] = Documents.list_documents(scope, query: "page")
    end

    test "broadcasts changes", %{scope: scope} do
      Documents.subscribe(scope)
      doc = document_fixture(scope)
      assert_receive {:document_created, id} when id == doc.id
      fake_ready!(doc)
      assert_receive {:document_updated, ^id}
    end
  end
end
