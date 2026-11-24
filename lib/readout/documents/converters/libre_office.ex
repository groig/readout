defmodule Readout.Documents.Converters.LibreOffice do
  @moduledoc """
  Office → PDF with LibreOffice headless.

  Every conversion gets a throwaway user profile (so jobs never share state or
  lock each other), with macros disabled and untrusted referer links blocked.
  It runs under a timeout and, where available, without network access (see
  `Readout.Documents.Tools`).
  """
  @behaviour Readout.Documents.Converter

  alias Readout.Documents.Tools

  @impl true
  def formats, do: [:docx, :pptx, :odt, :odp]

  @impl true
  def convert(input, _format, out_dir) do
    profile = Path.join(out_dir, "lo-profile")
    write_profile!(profile)

    args = [
      "-env:UserInstallation=file://#{profile}",
      "--headless",
      "--invisible",
      "--norestore",
      "--nologo",
      "--nodefault",
      "--nolockcheck",
      "--convert-to",
      "pdf",
      "--outdir",
      out_dir,
      input
    ]

    pdf = Path.join(out_dir, Path.rootname(Path.basename(input)) <> ".pdf")

    case Tools.run("soffice", args, env: [{"HOME", profile}]) do
      {:ok, output} ->
        if File.regular?(pdf), do: {:ok, pdf}, else: {:error, {:conversion_failed, output}}

      error ->
        error
    end
  end

  @doc false
  # A throwaway user profile: macros off, untrusted links blocked.
  def write_profile!(profile) do
    user = Path.join(profile, "user")
    File.mkdir_p!(user)

    File.write!(Path.join(user, "registrymodifications.xcu"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>
    </oor:items>
    """)
  end
end
