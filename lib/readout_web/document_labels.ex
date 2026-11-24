defmodule ReadoutWeb.DocumentLabels do
  @moduledoc "Translated labels for document formats, statuses and processing errors."
  use Gettext, backend: ReadoutWeb.Gettext

  def error_message("timeout"), do: gettext("Processing took too long and was stopped.")
  def error_message("no_pages"), do: gettext("The file has no pages.")
  def error_message("password"), do: gettext("The PDF is password-protected.")
  def error_message("unreadable"), do: gettext("The file couldn't be read. It may be damaged.")
  def error_message("conversion_failed"), do: gettext("The file couldn't be converted to PDF.")
  def error_message("unsupported"), do: gettext("This file type isn't supported.")

  def error_message("missing_tool:" <> tool),
    do: gettext("The server is missing a required tool (%{tool}).", tool: tool)

  def error_message(_), do: gettext("Something went wrong while processing the file.")

  @doc "Why an upload was refused."
  def upload_error(:too_large), do: gettext("The file is too large.")
  def upload_error(:empty), do: gettext("The file is empty.")

  def upload_error(:unsupported),
    do: gettext("Only PDF, Word, PowerPoint, ODT and ODP files are supported.")

  def upload_error(:too_many_files), do: gettext("Too many files at once.")

  def upload_error(:not_accepted),
    do: gettext("Only PDF, Word, PowerPoint, ODT and ODP files are supported.")

  def upload_error(:unauthorized), do: gettext("You can't upload documents.")
  def upload_error(_), do: gettext("The file couldn't be uploaded.")

  def format_label(:pdf), do: "PDF"
  def format_label(:docx), do: "Word"
  def format_label(:pptx), do: "PowerPoint"
  def format_label(:odt), do: "ODT"
  def format_label(:odp), do: "ODP"

  def status_label(:pending), do: gettext("Queued")
  def status_label(:processing), do: gettext("Processing")
  def status_label(:ready), do: gettext("Ready")
  def status_label(:failed), do: gettext("Failed")

  def visibility_label(:workspace), do: gettext("Workspace")
  def visibility_label(:restricted), do: gettext("Restricted")

  def member_role_label(:editor), do: gettext("Editor")
  def member_role_label(:viewer), do: gettext("Viewer")

  @doc "Human file size."
  def size(bytes) when bytes < 1024, do: "#{bytes} B"

  def size(bytes) when bytes < 1024 * 1024,
    do: "#{ReadoutWeb.Format.number(bytes / 1024, decimals: 0)} KB"

  def size(bytes), do: "#{ReadoutWeb.Format.number(bytes / 1024 / 1024, decimals: 1)} MB"
end
