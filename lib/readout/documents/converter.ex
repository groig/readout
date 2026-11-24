defmodule Readout.Documents.Converter do
  @moduledoc """
  Turns an uploaded original into a PDF, the format the rest of the pipeline
  (rasterizing, text extraction, downloads) works with.

  Each converter declares the formats it handles. Adding spreadsheets later is
  a new module listed in `converters/0`; PDFs pass through unchanged.
  """

  @doc "The formats this converter handles."
  @callback formats() :: [atom()]

  @doc "Converts `input` into a PDF inside `out_dir`, returning its path."
  @callback convert(input :: Path.t(), format :: atom(), out_dir :: Path.t()) ::
              {:ok, Path.t()} | {:error, term()}

  def converters, do: [Readout.Documents.Converters.LibreOffice]

  @doc "Produces a PDF for any supported format."
  def to_pdf(input, :pdf, _out_dir), do: {:ok, input}

  def to_pdf(input, format, out_dir) do
    case Enum.find(converters(), &(format in &1.formats())) do
      nil -> {:error, {:unsupported_format, format}}
      converter -> converter.convert(input, format, out_dir)
    end
  end
end
