defmodule Readout.Documents.SheetsTest do
  use ExUnit.Case, async: true

  import Readout.DocumentsFixtures
  alias Readout.Documents.{FileType, Sheets}

  test "detects spreadsheets" do
    assert FileType.detect(file_path("sample.xlsx")) == {:ok, :xlsx}
    assert FileType.detect(file_path("sample.ods")) == {:ok, :ods}
    assert FileType.detect(file_path("sample.csv"), "report.csv") == {:ok, :csv}
    # CSV needs a CSV name; binary files never pass as CSV.
    assert FileType.detect(file_path("sample.csv"), "report.txt") == {:error, :unsupported}
    assert FileType.detect(file_path("sample.pdf"), "x.csv") == {:ok, :pdf}
  end

  test "parses CSV: quotes, escaped quotes, newlines, sniffed delimiter, BOM, Latin-1" do
    assert Sheets.parse_csv(~s(a,b\n1,"x, y"\n2,"he said ""hi"""\n)) ==
             [["a", "b"], ["1", "x, y"], ["2", ~s(he said "hi")]]

    assert Sheets.parse_csv("﻿name;amount\r\nAna;1.234,5\r\n") == [
             ["name", "amount"],
             ["Ana", "1.234,5"]
           ]

    assert Sheets.parse_csv("a\tb\n1\t2") == [["a", "b"], ["1", "2"]]
    assert Sheets.parse_csv(~s(k,v\n1,"two\nlines")) == [["k", "v"], ["1", "two\nlines"]]
    assert Sheets.parse_csv(<<"ciudad\nM", 0xE1, "laga\n">>) == [["ciudad"], ["Málaga"]]
  end

  test "limits apply while parsing: rows, cells per row, characters per cell" do
    wide = Enum.map_join(1..1_000, ",", &Integer.to_string/1)
    [row] = Sheets.parse_csv(wide)
    assert length(row) == 200

    [[long]] = Sheets.parse_csv(~s("#{String.duplicate("x", 50_000)}"))
    assert String.length(long) == 1_000

    many = String.duplicate("a,b\n", 30_000)
    assert length(Sheets.parse_csv(many)) == 20_002

    # Edge cases of the slicing parser.
    assert Sheets.parse_csv("a,b,\n1,2,") == [["a", "b", ""], ["1", "2", ""]]
    assert Sheets.parse_csv(~s("unterminated,x)) == [["unterminated,x"]]
    assert Sheets.parse_csv(~s("a"junk,b)) == [["ajunk", "b"]]
    assert Sheets.parse_csv("") == []
  end

  test "parses numbers as people write them" do
    assert Sheets.parse_number("1.234,56") == 1234.56
    assert Sheets.parse_number("1,234.56") == 1234.56
    assert Sheets.parse_number("12%") == 12.0
    assert Sheets.parse_number("€ 30") == 30.0
    assert Sheets.parse_number("(45)") == -45.0
    assert Sheets.parse_number("1200,5") == 1200.5
    assert Sheets.parse_number("n/a") == nil
  end

  test "CSV files become one sheet with numeric columns detected" do
    {:ok, [sheet]} = Sheets.extract(file_path("sample.csv"), :csv, System.tmp_dir!())
    assert sheet.header == ["Region", "Q1", "Q2", "Q3"]
    assert length(sheet.rows) == 2
    assert sheet.numeric == [false, true, true, true]
  end

  @tag :tools
  test "XLSX and ODS export every sheet, in order" do
    for name <- ["sample.xlsx", "sample.ods"] do
      dir = Path.join(System.tmp_dir!(), "sheets-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      format = if String.ends_with?(name, "xlsx"), do: :xlsx, else: :ods
      assert {:ok, [rev, customers]} = Sheets.extract(file_path(name), format, dir)
      assert rev.name == "Revenue" and customers.name == "Customers"
      assert customers.rows == [["Acme", "Spain"]]
    end
  end
end
