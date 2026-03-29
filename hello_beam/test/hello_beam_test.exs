defmodule HelloBeamTest do
  use ExUnit.Case
  doctest HelloBeam

  test "greets the world" do
    assert HelloBeam.hello() == :world
  end
end
