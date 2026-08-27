defmodule Throttle.BlockExpirationTest do
  use ExUnit.Case, async: true

  alias Throttle.BlockExpiration

  test "parses HubSpot fixed-length ISO 8601 durations" do
    assert {:ok, 1_209_600} = BlockExpiration.seconds("P2W")
    assert {:ok, 608_400} = BlockExpiration.seconds("P1WT1H")
    assert {:ok, 93_784} = BlockExpiration.seconds("P1DT2H3M4S")
  end

  test "rejects zero, calendar-dependent, and malformed durations" do
    assert {:error, _} = BlockExpiration.seconds("P0D")
    assert {:error, _} = BlockExpiration.seconds("P1M")
    assert {:error, _} = BlockExpiration.seconds("two weeks")
  end
end
