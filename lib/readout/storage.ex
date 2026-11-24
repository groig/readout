defmodule Readout.Storage do
  @moduledoc """
  Where files live. Keys are relative paths like
  `documents/<id>/v1/original.docx`.

  The adapter is configurable (`config :readout, Readout.Storage, adapter: ...`).
  `Readout.Storage.Local` stores under `STORAGE_PATH`; an S3-compatible adapter
  can implement the same callbacks later. Nothing in storage is ever public:
  files are served only by controllers that check access first.
  """

  @doc "Copies a local file into storage under `key`."
  @callback put_file(key :: String.t(), source_path :: Path.t()) :: :ok | {:error, term()}

  @doc "Copies a stored file to a local path (for processing)."
  @callback fetch_file(key :: String.t(), dest_path :: Path.t()) :: :ok | {:error, term()}

  @doc """
  How to serve a stored file: a local path to `send_file`, or (for remote
  adapters) a short-lived URL to redirect to.
  """
  @callback serve(key :: String.t()) ::
              {:path, Path.t()} | {:url, String.t()} | {:error, :not_found}

  @doc "Deletes every file under a key prefix."
  @callback delete_prefix(prefix :: String.t()) :: :ok

  @callback exists?(key :: String.t()) :: boolean()

  def put_file(key, source_path), do: adapter().put_file(validate!(key), source_path)
  def fetch_file(key, dest_path), do: adapter().fetch_file(validate!(key), dest_path)
  def serve(key), do: adapter().serve(validate!(key))
  def delete_prefix(prefix), do: adapter().delete_prefix(validate!(prefix))
  def exists?(key), do: adapter().exists?(validate!(key))

  defp adapter, do: Application.fetch_env!(:readout, __MODULE__)[:adapter]

  # Keys are built by our code, never from user input, but refuse anything that
  # could escape the storage root anyway.
  defp validate!(key) when is_binary(key) do
    if key == "" or String.starts_with?(key, "/") or ".." in Path.split(key) do
      raise ArgumentError, "invalid storage key: #{inspect(key)}"
    end

    key
  end
end
