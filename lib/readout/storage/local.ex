defmodule Readout.Storage.Local do
  @moduledoc "Stores files on local disk under the configured root (`STORAGE_PATH`)."
  @behaviour Readout.Storage

  @impl true
  def put_file(key, source_path) do
    dest = path(key)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         # Copy to a temp name first, then rename: readers never see half a file.
         tmp = dest <> ".part-#{System.unique_integer([:positive])}",
         {:ok, _} <- File.copy(source_path, tmp),
         :ok <- File.rename(tmp, dest) do
      :ok
    end
  end

  @impl true
  def fetch_file(key, dest_path) do
    case File.copy(path(key), dest_path) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def serve(key) do
    path = path(key)
    if File.regular?(path), do: {:path, path}, else: {:error, :not_found}
  end

  @impl true
  def delete_prefix(prefix) do
    File.rm_rf(path(prefix))
    :ok
  end

  @impl true
  def exists?(key), do: File.regular?(path(key))

  @doc false
  def path(key), do: Path.join(root(), key)

  defp root, do: Application.fetch_env!(:readout, Readout.Storage)[:root]
end
