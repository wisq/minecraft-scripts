defmodule McscriptsTest do
  use ExUnit.Case
  doctest Mcscripts

  test "greets the world" do
    assert Mcscripts.hello() == :world
  end
end
