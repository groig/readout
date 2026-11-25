# Development only: fills a document's analytics with 30 days of realistic
# visits, so the dashboards have something to show in design reviews.
#
#     mix run priv/repo/demo_analytics.exs ["Document title"]
#
# Uses the given document (or the most recently updated one) and its links,
# creating two links if it has none.

import Ecto.Query
alias Readout.{Analytics, Documents, Links, Repo}
alias Readout.Accounts.Scope

if Mix.env() == :prod, do: raise("demo data is for development only")

owner = Repo.one!(from u in Readout.Accounts.User, where: u.role == :owner, limit: 1)
scope = Scope.for_user(owner)
title = List.first(System.argv())

doc =
  scope
  |> Documents.list_documents(query: title)
  |> Enum.find(& &1.current_version)
  |> Kernel.||(raise "no ready document found")
  |> then(&Documents.get_document(scope, &1.id))

links =
  case Links.list_links(scope, doc) do
    [] ->
      for name <- ["Client X", "Investors"] do
        {:ok, link} = Links.create_link(scope, doc, %{"name" => name, "require_email" => "true"})
        link
      end

    links ->
      links
  end

pages = doc.current_version.page_count

people = [
  {"ana.garcia@clientx.example", "88.26.241.248"},
  {"jorge@clientx.example", "193.146.141.31"},
  {"marie@fund.example", "90.84.33.12"},
  {"ben@fund.example", "8.8.4.4"},
  {nil, "2a00:1450:4003:80e::200e"},
  {nil, "81.45.60.1"},
  {"lucia@board.example", "83.44.10.200"}
]

:rand.seed(:exsss, {1, 2, 3})

for _ <- 1..45 do
  {email, ip} = Enum.random(people)
  link = Enum.random(links)
  {:ok, link} = Links.fetch_public_link(link.slug)

  visit = Links.start_visit!(link, %{email: email, email_verified: email != nil, ip: ip, user_agent: "Demo"})
  started = DateTime.add(DateTime.utc_now(), -:rand.uniform(30 * 24 * 3600), :second)

  # Most readers finish the first pages; fewer reach the end.
  reached = Enum.max([1, round(pages * :math.pow(:rand.uniform(), 0.6))])
  ms = Map.new(1..reached, fn p -> {p, round((25 + :rand.uniform(80)) * 1000 / (1 + p * 0.15))} end)
  views = Map.new(1..reached, &{&1, 1})

  visit = Analytics.record(visit, ms, views, reached)
  duration = ms |> Map.values() |> Enum.sum()

  visit
  |> Ecto.Changeset.change(
    started_at: started,
    last_seen_at: DateTime.add(started, div(duration, 1000)),
    ended_at: DateTime.add(started, div(duration, 1000))
  )
  |> Repo.update!()
end

IO.puts("Added 45 demo visits to “#{doc.title}”.")
