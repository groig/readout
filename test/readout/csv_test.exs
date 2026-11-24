defmodule Readout.CSVTest do
  use ExUnit.Case, async: true

  test "quotes, escapes and defuses formulas" do
    out =
      [["a", "b,c", "say \"hi\"", nil, 3, 1.5, "=SUM(A1)", "-1", "line\nbreak"]]
      |> Readout.CSV.encode()
      |> IO.iodata_to_binary()

    assert out == "﻿a,\"b,c\",\"say \"\"hi\"\"\",,3,1.5,'=SUM(A1),'-1,\"line\nbreak\"\r\n"
  end
end
