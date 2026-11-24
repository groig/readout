defmodule Readout.DocumentsFixtures do
  @moduledoc "Test helpers for documents. Sample files live in test/support/files."

  alias Readout.Documents

  def file_path(name), do: Path.expand("../files/#{name}", __DIR__)

  def upload(name), do: %{path: file_path(name), filename: name}

  @doc "Uploads a sample file as the scope's user. Not processed (see process!/1)."
  def document_fixture(scope, name \\ "sample.pdf") do
    {:ok, document} = Documents.create_document(scope, upload(name))
    document
  end

  @doc "Runs the processing job for the document's latest version, synchronously."
  def process!(document) do
    version =
      Readout.Repo.get_by!(Readout.Documents.Version,
        document_id: document.id,
        number: latest_number(document)
      )

    :ok =
      Oban.Testing.perform_job(Readout.Documents.ProcessVersion, %{"version_id" => version.id},
        repo: Readout.Repo
      )

    Readout.Repo.reload!(version)
  end

  defp latest_number(document) do
    import Ecto.Query

    Readout.Repo.one!(
      from v in Readout.Documents.Version,
        where: v.document_id == ^document.id,
        select: max(v.number)
    )
  end

  @doc "Marks a version ready with fake pages, without running the tools."
  def fake_ready!(document, pages \\ 2) do
    import Ecto.Query

    version =
      Readout.Repo.one!(
        from v in Readout.Documents.Version,
          where: v.document_id == ^document.id,
          order_by: [desc: v.number],
          limit: 1
      )

    {:ok, version} =
      Documents.complete_version(
        version,
        %{pdf_key: version.original_key, page_count: pages, metadata: %{}},
        for(n <- 1..pages, do: %{width: 595.0, height: 842.0, text: "page #{n} text"})
      )

    version
  end
end
