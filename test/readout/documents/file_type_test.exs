defmodule Readout.Documents.FileTypeTest do
  use ExUnit.Case, async: true

  import Readout.DocumentsFixtures
  alias Readout.Documents.FileType

  test "detects formats by content" do
    assert FileType.detect(file_path("sample.pdf")) == {:ok, :pdf}
    assert FileType.detect(file_path("sample.docx")) == {:ok, :docx}
    assert FileType.detect(file_path("sample.pptx")) == {:ok, :pptx}
    assert FileType.detect(file_path("sample.odt")) == {:ok, :odt}
    assert FileType.detect(file_path("sample.odp")) == {:ok, :odp}
  end

  test "ignores misleading extensions" do
    assert FileType.detect(file_path("fake.pdf")) == {:error, :unsupported}

    tmp = Path.join(System.tmp_dir!(), "renamed-#{System.unique_integer([:positive])}.txt")
    File.cp!(file_path("sample.docx"), tmp)
    assert FileType.detect(tmp) == {:ok, :docx}
  end

  test "rejects other zips and missing files" do
    tmp = Path.join(System.tmp_dir!(), "plain-#{System.unique_integer([:positive])}.zip")
    {:ok, _} = :zip.create(String.to_charlist(tmp), [{~c"hello.txt", "hi"}])
    assert FileType.detect(tmp) == {:error, :unsupported}
    assert FileType.detect("/nonexistent/file") == {:error, :unsupported}
  end

  test "never expands a compressed mimetype entry (archive bombs)" do
    tmp = Path.join(System.tmp_dir!(), "bomb-#{System.unique_integer([:positive])}.odt")
    on_exit(fn -> File.rm(tmp) end)

    # 64 MB of "text" that deflates to a few KB.
    huge = "application/vnd.oasis.opendocument.text" <> :binary.copy("0", 64 * 1024 * 1024)
    {:ok, _} = :zip.create(String.to_charlist(tmp), [{~c"mimetype", huge}])
    assert File.stat!(tmp).size < 1_000_000

    {:memory, before} = Process.info(self(), :memory)
    assert FileType.detect(tmp) == {:error, :unsupported}
    {:memory, after_} = Process.info(self(), :memory)
    assert after_ - before < 10_000_000
  end
end
