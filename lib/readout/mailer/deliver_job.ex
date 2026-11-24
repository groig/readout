defmodule Readout.Mailer.DeliverJob do
  @moduledoc "Delivers one email in the background (queue `mailers`), with retries."
  use Oban.Worker, queue: :mailers, max_attempts: 5

  @salt "mailer job"

  def new_job(%Swoosh.Email{} = email) do
    payload = Plug.Crypto.encrypt(secret(), @salt, :erlang.term_to_binary(email))
    new(%{"email" => payload})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => payload}}) do
    with {:ok, binary} <- Plug.Crypto.decrypt(secret(), @salt, payload, max_age: :infinity),
         %Swoosh.Email{} = email <- :erlang.binary_to_term(binary, [:safe]),
         {:ok, _} <- Readout.Mailer.deliver(email) do
      :ok
    else
      {:error, :invalid} -> {:cancel, :undecryptable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret, do: ReadoutWeb.Endpoint.config(:secret_key_base)
end
