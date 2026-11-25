defmodule Readout.Documents.WatermarkTest do
  use ReadoutWeb.ConnCase, async: false

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Documents.{PdfWriter, Tools, Watermark}
  alias Readout.Links
  alias ReadoutWeb.ViewerAccess

  @moduletag :tools
  @moduletag timeout: 300_000

  setup do
    scope = Scope.for_user(user_fixture())
    doc = document_fixture(scope, "sample.pdf")
    _version = process!(doc)
    doc = Readout.Documents.get_document(scope, doc.id)
    %{scope: scope, doc: doc}
  end

  defp visit_for(scope, doc, attrs) do
    {:ok, link} =
      Links.create_link(
        scope,
        doc,
        Map.merge(%{"name" => "x", "allow_download" => "true"}, attrs)
      )

    {:ok, link} = Links.fetch_public_link(link.slug)
    visit = Links.start_visit!(link, %{email: "ana@client.com"})
    {link, visit, ViewerAccess.sign_visit(visit.id, link.access_revision)}
  end

  test "watermarked links serve images with the visit burned in", %{
    conn: conn,
    scope: scope,
    doc: doc
  } do
    {plain_link, _, plain_token} = visit_for(scope, doc, %{})
    {link, visit, token} = visit_for(scope, doc, %{"watermark" => "true"})

    plain = response(get(conn, ~p"/v/#{plain_link.slug}/p/#{plain_token}/1/480"), 200)
    marked = response(get(build_conn(), ~p"/v/#{link.slug}/p/#{token}/1/480"), 200)

    assert <<"RIFF", _::32, "WEBP", _::binary>> = marked
    refute marked == plain
    assert Watermark.text(visit) =~ "ana@client.com"
    assert Watermark.text(visit) =~ String.slice(String.replace(visit.id, "-", ""), 0, 8)
  end

  test "watermarked PDF downloads are rebuilt from the marked pages", %{
    conn: conn,
    scope: scope,
    doc: doc
  } do
    {link, _visit, token} =
      visit_for(scope, doc, %{"watermark" => "true", "allow_original_download" => "true"})

    refute link.allow_original_download

    pdf = response(get(conn, ~p"/v/#{link.slug}/download/#{token}/pdf"), 200)
    path = Path.join(System.tmp_dir!(), "wm-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, pdf)
    assert {:ok, out} = Tools.run("pdfinfo", [path])
    assert out =~ ~r/Pages:\s+3/

    assert response(get(build_conn(), ~p"/v/#{link.slug}/download/#{token}/original"), 404)
  end

  test "the PDF writer reads JPEG sizes and writes a valid file" do
    dir = Path.join(System.tmp_dir!(), "pdfw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    jpeg = Path.join(dir, "a.jpg")

    {_, 0} =
      System.cmd(if(System.find_executable("magick"), do: "magick", else: "convert"), [
        "-size",
        "300x200",
        "xc:white",
        jpeg
      ])

    assert {300, 200, components} = PdfWriter.jpeg_info(File.read!(jpeg))
    assert components in [1, 3]

    out = Path.join(dir, "out.pdf")
    :ok = PdfWriter.write([{jpeg, 300.0, 200.0}, {jpeg, 300.0, 200.0}], out)
    assert {:ok, info} = Tools.run("pdfinfo", [out])
    assert info =~ ~r/Pages:\s+2/
    assert info =~ "300 x 200 pts"
  end

  test "old cached watermarks are pruned" do
    dir = Path.join([Watermark.cache_dir(), "watermarks", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    File.touch!(dir, System.os_time(:second) - 3 * 24 * 3600)
    :ok = Watermark.prune()
    refute File.exists?(dir)
  end
end
