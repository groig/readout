defmodule Readout.Documents.ToolsTest do
  # Sets an environment variable, so not async.
  use ExUnit.Case, async: false

  alias Readout.Documents.Tools

  @moduletag :tools

  setup do
    job = Path.join(System.tmp_dir!(), "readout-tools-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(job)
    on_exit(fn -> File.rm_rf(job) end)
    %{job: job}
  end

  test "tools get a minimal environment, without the app's secrets", %{job: job} do
    System.put_env("READOUT_TEST_SECRET", "hunter2")
    on_exit(fn -> System.delete_env("READOUT_TEST_SECRET") end)

    {:ok, out} = Tools.run("env", [], cd: job)
    refute out =~ "hunter2"
    assert out =~ "HOME=#{job}"
    assert out =~ "PATH="
  end

  test "memory, file size and CPU are limited", %{job: job} do
    {:ok, out} = Tools.run("sh", ["-c", "ulimit -d; ulimit -f; ulimit -t"], cd: job)
    assert [data, file, cpu] = String.split(out)
    assert String.to_integer(data) <= 2048 * 1024
    assert file != "unlimited" and cpu != "unlimited"
  end

  describe "with isolation" do
    @describetag :namespaces

    test "there is no network, only loopback", %{job: job} do
      {:ok, out} = Tools.run("cat", ["/proc/net/dev"], cd: job)

      interfaces =
        for line <- String.split(out, "\n"),
            [_, name] <- [Regex.run(~r/^\s*(\S+):/, line)],
            do: name

      assert interfaces == ["lo"]
    end

    test "the app's environment is unreadable", %{job: job} do
      environ = "/proc/#{System.pid()}/environ"
      assert File.read!(environ) =~ "PATH="
      assert {:error, {:exit, _, out}} = Tools.run("cat", [environ], cd: job)
      assert out =~ "Permission denied"
    end

    test "only the job directory is visible, not stored documents", %{job: job} do
      root = Application.fetch_env!(:readout, Readout.Storage)[:root]
      File.mkdir_p!(root)
      File.write!(Path.join(root, "secret-document.pdf"), "x")
      File.write!(Path.join(job, "input.pdf"), "x")
      on_exit(fn -> File.rm(Path.join(root, "secret-document.pdf")) end)

      {:ok, stored} = Tools.run("ls", ["-a", root], cd: job)
      refute stored =~ "secret-document"

      {:ok, own} = Tools.run("ls", [job], cd: job)
      assert own =~ "input.pdf"
    end
  end
end
