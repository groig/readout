# Tests that run LibreOffice and poppler are tagged :tools. They're skipped,
# with a note, when a required tool isn't installed.
missing_tools = Readout.Documents.Tools.missing()

exclude =
  if missing_tools == [] do
    []
  else
    IO.puts("Skipping :tools tests, missing: #{Enum.join(missing_tools, ", ")}")
    [:tools]
  end

# Tests of the tools' isolation need unprivileged user namespaces.
exclude =
  if missing_tools == [] and not Readout.Documents.Tools.network_isolation?() do
    IO.puts("Skipping :namespaces tests: unprivileged user namespaces are unavailable")
    [:namespaces | exclude]
  else
    exclude
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Readout.Repo, :manual)
