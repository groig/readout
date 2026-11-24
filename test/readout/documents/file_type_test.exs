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
end
