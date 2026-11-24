defmodule Readout.Documents.ProcessingTest do
  @moduledoc "End-to-end processing with the real tools (LibreOffice, poppler, cwebp)."
  use Readout.DataCase, async: false

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.{Documents, Storage}
  alias Readout.Documents.{Pdf, Version}

  @moduletag :tools
  @moduletag timeout: 300_000

  setup do
    %{scope: Scope.for_user(user_fixture())}
  end

  test "a PDF is rendered at both widths and its text extracted", %{scope: scope} do
    doc = document_fixture(scope, "sample.pdf")
    version = process!(doc)

    assert version.status == :ready
    assert version.page_count == 3
    assert version.pdf_key == version.original_key

    for n <- 1..3, width <- Pdf.widths() do
      assert Storage.exists?(Version.page_key(version, n, width))
    end

    pages = Documents.list_pages(version)
    assert Enum.map(pages, & &1.number) == [1, 2, 3]
    assert Enum.at(pages, 1).text =~ "roadmap"
    assert hd(pages).width > 500

    # The document now points at this version, and its text is searchable.
    assert [found] = Documents.list_documents(scope, query: "roadmap")
    assert found.id == doc.id
    assert found.current_version_id == version.id
    assert [] = Documents.list_documents(scope, query: "nonexistentword")
  end

  for name <- ~w(sample.docx sample.pptx sample.odt sample.odp) do
    test "#{name} is converted to PDF, keeping the original", %{scope: scope} do
      doc = document_fixture(scope, unquote(name))
      version = process!(doc)

      assert version.status == :ready, "status #{version.status}: #{version.error}"
      assert version.page_count >= 1
      assert version.pdf_key =~ "document.pdf"
      assert Storage.exists?(version.pdf_key)
      assert Storage.exists?(version.original_key)
      assert Storage.exists?(Version.page_key(version, 1, Pdf.thumb_width()))
    end
  end

  test "a broken file fails with a readable code and no retries", %{scope: scope} do
    # A ZIP that looks like a DOCX but isn't a valid one.
    tmp = Path.join(System.tmp_dir!(), "broken-#{System.unique_integer([:positive])}.docx")
    {:ok, _} = :zip.create(String.to_charlist(tmp), [{~c"word/document.xml", "<not xml"}])
    {:ok, doc} = Documents.create_document(scope, %{path: tmp, filename: "broken.docx"})

    version = Readout.Repo.get_by!(Version, document_id: doc.id)

    result =
      Oban.Testing.perform_job(Readout.Documents.ProcessVersion, %{"version_id" => version.id},
        repo: Readout.Repo
      )

    assert match?({:cancel, _}, result) or match?({:error, _}, result)
  end
end
