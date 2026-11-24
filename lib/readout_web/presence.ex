defmodule ReadoutWeb.Presence do
  @moduledoc """
  Who is reading right now. Each open viewer is tracked (keyed by visit id)
  on `"reading:<document_id>"` and on the workspace-wide `"reading"` topic,
  with its current page in the metadata.
  """
  use Phoenix.Presence, otp_app: :readout, pubsub_server: Readout.PubSub

  def document_topic(document_id), do: "reading:" <> document_id
  def workspace_topic, do: "reading"

  @doc "Readers of one document: a list of metas."
  def readers(document_id), do: document_id |> document_topic() |> list() |> metas()

  @doc "Readers across the workspace."
  def all_readers, do: workspace_topic() |> list() |> metas()

  defp metas(presences) do
    for {_key, %{metas: [meta | _]}} <- presences, do: meta
  end
end
