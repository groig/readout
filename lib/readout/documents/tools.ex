defmodule Readout.Documents.Tools do
  @moduledoc """
  Runs the external tools (LibreOffice, poppler, cwebp) safely:

    * always under coreutils `timeout`, so a hung converter is killed;
    * without network access (`unshare --net`) when the kernel allows
      unprivileged user namespaces, which is probed once and cached;
    * with output captured and errors returned, never raised.
  """
  require Logger

  @doc """
  Runs `executable` with `args`. Options: `:timeout` (seconds), `:cd`, `:env`,
  `:isolate_network` (default true).
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error, {:exit, integer(), String.t()} | :timeout | {:missing_tool, String.t()}}
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())

    with {:ok, exe} <- find(executable) do
      {cmd, cmd_args} = wrap(exe, args, timeout, Keyword.get(opts, :isolate_network, true))

      cmd_opts =
        [stderr_to_stdout: true]
        |> maybe_put(:cd, opts[:cd])
        |> maybe_put(:env, opts[:env])

      case System.cmd(cmd, cmd_args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {_output, code} when code in [124, 137] -> {:error, :timeout}
        {output, code} -> {:error, {:exit, code, String.slice(output, -2000, 2000)}}
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp find(executable) do
    case System.find_executable(executable) do
      nil -> {:error, {:missing_tool, executable}}
      path -> {:ok, path}
    end
  end

  defp wrap(exe, args, timeout, isolate?) do
    timeout_args = ["--kill-after=10", Integer.to_string(timeout)]

    if isolate? and network_isolation?() do
      {"timeout", timeout_args ++ ["unshare", "--net", "--map-root-user", exe | args]}
    else
      {"timeout", timeout_args ++ [exe | args]}
    end
  end

  @doc "Whether tools run without network access on this host."
  def network_isolation? do
    case :persistent_term.get({__MODULE__, :isolation}, :unknown) do
      :unknown ->
        available? =
          match?(
            {_, 0},
            System.cmd("unshare", ["--net", "--map-root-user", "true"], stderr_to_stdout: true)
          )

        unless available? do
          Logger.warning("unshare is not available: document tools run without network isolation")
        end

        :persistent_term.put({__MODULE__, :isolation}, available?)
        available?

      value ->
        value
    end
  rescue
    ErlangError -> false
  end

  @doc "Whether every required tool is installed."
  def missing do
    Enum.reject(~w(timeout soffice pdfinfo pdftoppm pdftotext cwebp), &System.find_executable/1)
  end

  defp default_timeout, do: Application.get_env(:readout, Readout.Documents)[:tool_timeout] || 180
end
