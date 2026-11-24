defmodule Readout.Documents.WatermarkCleanup do
  @moduledoc "Daily: removes watermarked images and PDFs cached more than two days ago."
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: Readout.Documents.Watermark.prune()
end
