defmodule Readout.Documents.PdfWriter do
  @moduledoc """
  Writes a PDF from JPEG page images: one image per page, scaled to the page
  size in points. Small on purpose (no dependency): JPEG is embedded as-is
  (DCTDecode), so this is just the PDF object structure and a cross-reference
  table. Used for watermarked downloads.
  """

  @doc "`pages` is a list of `{jpeg_path, width_pt, height_pt}`."
  def write(pages, dest) when pages != [] do
    images = Enum.map(pages, fn {path, w, h} -> {File.read!(path), w, h} end)
    n = length(images)

    # Objects: 1 catalog, 2 pages, then per page: page, image, content.
    page_ids = for i <- 0..(n - 1), do: 3 + i * 3

    objects =
      [
        {1, "<< /Type /Catalog /Pages 2 0 R >>"},
        {2,
         "<< /Type /Pages /Kids [#{Enum.map_join(page_ids, " ", &"#{&1} 0 R")}] /Count #{n} >>"}
      ] ++
        (images
         |> Enum.with_index()
         |> Enum.flat_map(fn {{jpeg, w, h}, i} ->
           page_id = 3 + i * 3
           image_id = page_id + 1
           content_id = page_id + 2
           {px_w, px_h, components} = jpeg_info(jpeg)
           color = if components == 1, do: "/DeviceGray", else: "/DeviceRGB"
           w = fmt(w)
           h = fmt(h)
           content = "q #{w} 0 0 #{h} 0 0 cm /Im0 Do Q"

           [
             {page_id,
              "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{w} #{h}] " <>
                "/Resources << /XObject << /Im0 #{image_id} 0 R >> >> /Contents #{content_id} 0 R >>"},
             {image_id,
              {"<< /Type /XObject /Subtype /Image /Width #{px_w} /Height #{px_h} /ColorSpace #{color} " <>
                 "/BitsPerComponent 8 /Filter /DCTDecode /Length #{byte_size(jpeg)} >>", jpeg}},
             {content_id, {"<< /Length #{byte_size(content)} >>", content}}
           ]
         end))

    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets} =
      Enum.reduce(objects, {[header], []}, fn {id, obj}, {acc, offs} ->
        offset = IO.iodata_length(acc)

        chunk =
          case obj do
            {dict, stream} ->
              ["#{id} 0 obj\n", dict, "\nstream\n", stream, "\nendstream\nendobj\n"]

            dict ->
              ["#{id} 0 obj\n", dict, "\nendobj\n"]
          end

        {[acc, chunk], [{id, offset} | offs]}
      end)

    xref_at = IO.iodata_length(body)
    count = length(objects) + 1

    xref =
      ["xref\n0 #{count}\n0000000000 65535 f \n"] ++
        for {_id, off} <- Enum.sort(offsets),
            do: String.pad_leading(Integer.to_string(off), 10, "0") <> " 00000 n \n"

    trailer = "trailer\n<< /Size #{count} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    File.write(dest, [body, xref, trailer])
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: Integer.to_string(n)

  @doc false
  # Width, height and colour components from the JPEG's SOF marker.
  def jpeg_info(<<0xFF, 0xD8, rest::binary>>), do: scan(rest)

  defp scan(<<0xFF, marker, _len::16, _precision, h::16, w::16, components, _::binary>>)
       when marker in [0xC0, 0xC1, 0xC2],
       do: {w, h, components}

  defp scan(<<0xFF, marker, len::16, rest::binary>>)
       when marker not in [0xD8, 0x01] and marker not in 0xD0..0xD7 do
    skip = len - 2
    <<_::binary-size(skip), next::binary>> = rest
    scan(next)
  end

  defp scan(<<_, rest::binary>>), do: scan(rest)
end
