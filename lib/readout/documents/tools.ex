defmodule Readout.Documents.Tools do
  @moduledoc """
  Runs the external tools (LibreOffice, poppler, cwebp, ImageMagick) on
  untrusted documents, contained:

    * **Time**: under coreutils `timeout`, so a hung converter is killed.
    * **Resources**: `prlimit` caps memory (`:tool_memory_mb`), CPU
      seconds (the timeout), the size of any file written (`:tool_file_mb`),
      open files and core dumps.
    * **Environment**: a minimal one (`PATH`, `HOME`, `TMPDIR`, `LANG`), so
      secrets such as `DATABASE_URL` or `SECRET_KEY_BASE` never reach a tool.
    * **Isolation** (`unshare`): no network (an empty network namespace); its
      own user namespace, so the app's process environments
      (`/proc/<pid>/environ`) are unreadable and it can't signal the app; its
      own PID namespace (children die with it); and empty filesystems mounted
      over the storage directory, the watermark cache and the release, so a
      tool sees only its job directory and the system. (`/proc` isn't
      remounted: Docker forbids that unless its `/proc` masks are lifted.)

  Isolation needs unprivileged user namespaces. It is probed once and cached.
  With `isolation: :required` (production's default) a tool never runs
  without it: `run/3` returns `{:error, :isolation_unavailable}` and the job
  fails. `:preferred` (development and tests) runs without it and warns.
  """
  require Logger

  @doc """
  Runs `executable` with `args`. Options: `:timeout` (seconds), `:cd` (the
  job directory, also `HOME` and `TMPDIR`), `:env` (extra variables).
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error,
             {:exit, integer(), String.t()}
             | :timeout
             | :isolation_unavailable
             | {:missing_tool, String.t()}}
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, config(:tool_timeout, 180))
    workdir = opts[:cd] || System.tmp_dir!()

    with {:ok, exe} <- find(executable),
         {:ok, isolated?} <- isolation() do
      {cmd, cmd_args} = wrap(exe, args, timeout, workdir, isolated?)

      cmd_opts = [stderr_to_stdout: true, cd: workdir, env: env(workdir, opts[:env] || [])]

      case System.cmd(cmd, cmd_args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {_output, code} when code in [124, 137] -> {:error, :timeout}
        {output, code} -> {:error, {:exit, code, String.slice(output, -2000, 2000)}}
      end
    end
  end

  defp find(executable) do
    case System.find_executable(executable) do
      nil -> {:error, {:missing_tool, executable}}
      path -> {:ok, path}
    end
  end

  defp isolation do
    cond do
      network_isolation?() -> {:ok, true}
      config(:isolation, :required) == :required -> {:error, :isolation_unavailable}
      true -> {:ok, false}
    end
  end

  # Everything the app inherited is removed; only these reach the tool.
  defp env(workdir, extra) do
    keep = %{
      "PATH" => System.get_env("PATH", "/usr/local/bin:/usr/bin:/bin"),
      "HOME" => workdir,
      "TMPDIR" => workdir,
      "LANG" => "C.UTF-8"
    }

    cleared = for {name, _} <- System.get_env(), not Map.has_key?(keep, name), do: {name, nil}
    cleared ++ Enum.to_list(keep) ++ extra
  end

  # timeout → prlimit → unshare → sh (mount the empty filesystems, cd) → tool.
  defp wrap(exe, args, timeout, workdir, isolated?) do
    limits = [
      # The data limit (heap and private writable mappings), not the address
      # space: LibreOffice reserves far more address space than it uses.
      "--data=#{config(:tool_memory_mb, 2048) * 1024 * 1024}",
      "--fsize=#{config(:tool_file_mb, 2048) * 1024 * 1024}",
      "--cpu=#{timeout}",
      "--nofile=1024",
      "--core=0",
      "--"
    ]

    command =
      if isolated?,
        do: isolate(hidden_dirs(workdir), workdir, [exe | args]),
        else: [exe | args]

    {"timeout", ["--kill-after=10", Integer.to_string(timeout), "prlimit" | limits] ++ command}
  end

  @script ~S"""
  set -e
  work="$1"; n="$2"; shift 2
  while [ "$n" -gt 0 ]; do
    if [ -d "$1" ]; then mount -t tmpfs -o size=64k,mode=0500 readout-hidden "$1"; fi
    shift; n=$((n - 1))
  done
  cd "$work"
  exec "$@"
  """

  defp isolate(hidden, workdir, command) do
    ["unshare", "--net", "--pid", "--fork", "--kill-child", "--mount", "--map-root-user"] ++
      ["--", "sh", "-c", @script, "readout-tool", workdir, Integer.to_string(length(hidden))] ++
      hidden ++ command
  end

  # Directories a tool has no business reading: every stored document, the
  # watermark cache and the release (its runtime config). Never the job's
  # own directory.
  defp hidden_dirs(workdir) do
    [
      Application.get_env(:readout, Readout.Storage)[:root],
      Application.get_env(:readout, :cache_dir) ||
        Path.join(System.tmp_dir!(), "readout-cache"),
      System.get_env("RELEASE_ROOT")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&String.starts_with?(Path.expand(workdir) <> "/", &1 <> "/"))
    |> Enum.uniq()
  end

  @doc "Whether tools run isolated (namespaces available) on this host."
  def network_isolation? do
    case :persistent_term.get({__MODULE__, :isolation}, :unknown) do
      :unknown ->
        available? = probe()

        unless available? do
          level = if config(:isolation, :required) == :required, do: :error, else: :warning

          Logger.log(
            level,
            "unprivileged user namespaces are unavailable: document tools can't be isolated" <>
              if(level == :error, do: " and won't run", else: " (running them without isolation)")
          )
        end

        :persistent_term.put({__MODULE__, :isolation}, available?)
        available?

      value ->
        value
    end
  end

  # The same wrapper, hiding a scratch directory, running `true`.
  defp probe do
    dir = Path.join(System.tmp_dir!(), "readout-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      args = isolate([dir], System.tmp_dir!(), ["true"])
      match?({_, 0}, System.cmd(hd(args), tl(args), stderr_to_stdout: true))
    rescue
      ErlangError -> false
    after
      File.rm_rf(dir)
    end
  end

  @doc "Required tools that aren't installed."
  def missing do
    tools = ~w(timeout prlimit unshare mount soffice pdfinfo pdftoppm pdftotext cwebp fc-match)
    missing = Enum.reject(tools, &System.find_executable/1)
    # ImageMagick 7 (`magick`) or 6 (`convert`), for watermarks.
    if System.find_executable("magick") || System.find_executable("convert"),
      do: missing,
      else: missing ++ ["magick"]
  end

  defp config(key, default),
    do: Application.get_env(:readout, Readout.Documents)[key] || default
end
