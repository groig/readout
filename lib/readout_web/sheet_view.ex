defmodule ReadoutWeb.SheetView do
  @moduledoc """
  State and events of the spreadsheet viewer, shared by the document page and
  the public viewer. Assigns `:sheet` (a map) and the `:sheet_rows` stream;
  LiveViews delegate `"sheet:" <> _` events to `handle_event/3`.

  The whole current sheet is kept in the LiveView (it is capped at 20,000
  rows); only the visible page of rows is rendered.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_configure: 3]

  alias Readout.Documents.{Sheets, Version}

  @page_size 100
  @chart_rows 40

  def page_size, do: @page_size

  @doc "Opens the first sheet of a version."
  def init(socket, %Version{} = version) do
    socket
    |> stream_configure(:sheet_rows, dom_id: &"sheet-row-#{elem(&1, 0)}")
    |> assign(:sheet, %{
      version: version,
      names: sheet_names(version),
      index: 1,
      page: 1,
      mode: :table,
      column: nil,
      data: nil
    })
    |> load(1)
  end

  defp sheet_names(%Version{metadata: %{"sheets" => sheets}}), do: Enum.map(sheets, & &1["name"])
  defp sheet_names(_), do: []

  @doc "Handles a viewer event; returns the socket."
  def handle_event("sheet:select", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {n, ""} when n >= 1 ->
        if n <= length(socket.assigns.sheet.names), do: load(socket, n), else: socket

      _ ->
        socket
    end
  end

  def handle_event("sheet:page", %{"page" => page}, socket) do
    sheet = socket.assigns.sheet

    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 1 and n <= sheet.pages -> show_page(socket, n)
      _ -> socket
    end
  end

  def handle_event("sheet:mode", %{"mode" => mode}, socket) when mode in ["table", "chart"] do
    update_sheet(socket, mode: String.to_existing_atom(mode))
  end

  def handle_event("sheet:column", %{"column" => column}, socket) do
    case Integer.parse(to_string(column)) do
      {n, ""} ->
        if n in socket.assigns.sheet.numeric_columns,
          do: update_sheet(socket, column: n),
          else: socket

      _ ->
        socket
    end
  end

  def handle_event(_event, _params, socket), do: socket

  defp load(socket, index) do
    sheet = socket.assigns.sheet

    data =
      case Sheets.load(sheet.version, index) do
        {:ok, data} -> data
        {:error, _} -> %{"header" => [], "rows" => [], "numeric" => [], "truncated" => false}
      end

    numeric = data["numeric"] || []
    numeric_columns = for {true, i} <- Enum.with_index(numeric), do: i
    rows = data["rows"] || []

    socket
    |> update_sheet(
      index: index,
      data: data,
      header: data["header"] || [],
      numeric: numeric,
      numeric_columns: numeric_columns,
      label_column: Enum.find_index(numeric, &(!&1)),
      column: List.first(numeric_columns),
      row_count: length(rows),
      pages: max(1, ceil(length(rows) / @page_size)),
      truncated: data["truncated"] || false,
      mode: if(numeric_columns == [], do: :table, else: sheet.mode)
    )
    |> show_page(1)
  end

  defp show_page(socket, page) do
    rows = socket.assigns.sheet.data["rows"] || []
    first = (page - 1) * @page_size

    visible =
      rows
      |> Enum.slice(first, @page_size)
      |> Enum.with_index(first + 1)
      |> Enum.map(fn {row, n} -> {n, row} end)

    socket
    |> update_sheet(page: page)
    |> stream(:sheet_rows, visible, reset: true)
  end

  defp update_sheet(socket, changes),
    do: assign(socket, :sheet, Map.merge(socket.assigns.sheet, Map.new(changes)))

  @doc "Bars for the chart: the chosen number column, labelled by the first text column."
  def chart_bars(%{data: data, column: column, label_column: label} = _sheet)
      when is_integer(column) do
    (data["rows"] || [])
    |> Enum.take(@chart_rows)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {row, n} ->
      case Sheets.parse_number(Enum.at(row, column) || "") do
        nil ->
          []

        value ->
          name = if label, do: Enum.at(row, label), else: Integer.to_string(n)
          [%{label: name, value: max(value, 0), display: Enum.at(row, column), hint: name}]
      end
    end)
  end

  def chart_bars(_sheet), do: []

  def chart_rows, do: @chart_rows
end
