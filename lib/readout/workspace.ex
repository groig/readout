defmodule Readout.Workspace do
  @moduledoc """
  Workspace-wide settings (the name). One workspace for the whole team; only
  owners can change it.
  """

  alias Readout.Accounts.Scope
  alias Readout.{Audit, Policy, Repo}
  alias Readout.Workspace.Settings

  @topic "workspace:settings"

  @doc "Returns the settings row, creating it on first use."
  def get_settings do
    case Repo.get(Settings, 1) do
      nil ->
        Repo.insert!(%Settings{id: 1}, on_conflict: :nothing, conflict_target: :id)
        Repo.get!(Settings, 1)

      settings ->
        settings
    end
  end

  def change_settings(%Settings{} = settings, attrs \\ %{}) do
    Settings.changeset(settings, attrs)
  end

  def update_settings(%Scope{} = scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_workspace, :workspace),
         {:ok, settings} <- get_settings() |> Settings.changeset(attrs) |> Repo.update() do
      Audit.log(scope, "workspace.updated", nil, %{name: settings.name})

      Phoenix.PubSub.broadcast(Readout.PubSub, @topic, {:workspace_updated, settings})
      {:ok, settings}
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Readout.PubSub, @topic)
end
