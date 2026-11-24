defmodule Readout.GeoIPTest do
  use ExUnit.Case, async: true

  alias Readout.{GeoIP, GeoIPFixture}

  @madrid %{
    "country" => %{"iso_code" => "ES", "names" => %{"en" => "Spain", "es" => "España"}},
    "city" => %{"names" => %{"en" => "Madrid", "es" => "Madrid"}}
  }
  @paris %{"country" => %{"iso_code" => "FR", "names" => %{"en" => "France", "es" => "Francia"}}}
  @v6 %{"country" => %{"iso_code" => "DE", "names" => %{"en" => "Germany"}}}

  for version <- [4, 6] do
    test "looks up IPv4 addresses in an IPv#{version} database" do
      entries = [{"81.0.0.0/8", @madrid}, {"90.1.0.0/16", @paris}]
      {:ok, db} = GeoIP.open(GeoIPFixture.build(entries, unquote(version)))

      assert {:ok, %{"city" => %{"names" => %{"en" => "Madrid"}}}} = GeoIP.find(db, {81, 2, 3, 4})
      assert {:ok, %{"country" => %{"iso_code" => "FR"}}} = GeoIP.find(db, {90, 1, 200, 7})
      assert :not_found = GeoIP.find(db, {90, 2, 0, 1})
      assert :not_found = GeoIP.find(db, {10, 0, 0, 1})
    end
  end

  test "looks up IPv6 addresses" do
    {:ok, db} = GeoIP.open(GeoIPFixture.build([{"2a01::/16", @v6}], 6))
    {:ok, ip} = :inet.parse_address(~c"2a01:4f8::1")
    assert {:ok, %{"country" => %{"iso_code" => "DE"}}} = GeoIP.find(db, ip)
  end

  test "labels a location in the reader's language" do
    loc = %{
      country_code: "ES",
      country: %{"en" => "Spain", "es" => "España"},
      city: %{"en" => "Madrid"}
    }

    assert GeoIP.label(loc, "es") == "Madrid, España"
    assert GeoIP.label(loc, "en") == "Madrid, Spain"
    assert GeoIP.label(%{country: %{"en" => "France"}, city: %{}}, "es") == "France"
    assert GeoIP.label(nil, "en") == nil
  end

  test "rejects files that aren't MaxMind databases" do
    assert {:error, _} = GeoIP.open("definitely not a database")
  end

  test "without a configured database, lookups return nil" do
    assert GeoIP.lookup("81.2.3.4") == nil or is_map(GeoIP.lookup("81.2.3.4"))
    assert GeoIP.lookup("not an ip") == nil
    assert GeoIP.lookup(nil) == nil
  end
end
