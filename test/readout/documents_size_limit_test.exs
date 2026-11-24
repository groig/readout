defmodule Readout.DocumentsSizeLimitTest do
  # Changes global config, so it must not run alongside async tests.
  use Readout.DataCase, async: false

  import Readout.AccountsFixtures
  import Readout.DocumentsFixtures

  alias Readout.Accounts.Scope
  alias Readout.Documents

  test "enforces the size limit" do
    previous = Application.get_env(:readout, Readout.Documents)

    Application.put_env(
      :readout,
      Readout.Documents,
      Keyword.put(previous, :max_upload_bytes, 100)
    )

    on_exit(fn -> Application.put_env(:readout, Readout.Documents, previous) end)

    scope = Scope.for_user(user_fixture())
    assert {:error, :too_large} = Documents.create_document(scope, upload("sample.pdf"))
  end
end
