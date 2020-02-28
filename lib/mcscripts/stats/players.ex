defmodule Mcscripts.Stats.Players do
  require Logger
  alias Mcscripts.Rcon

  @player_header_regex ~r{^There are (?<cur>\d+)/(?<max>\d+) players online:$}

  def collect_player_list(state, batch) do
    [header_line, players_line] =
      Rcon.command!(state.rcon, "list")
      |> String.split("\n")

    players =
      case players_line do
        "" -> MapSet.new()
        str -> String.split(str, ", ") |> MapSet.new()
      end

    ops = MapSet.intersection(players, state.ops)
    non_ops = MapSet.difference(players, state.ops)

    %{"cur" => current, "max" => max} = Regex.named_captures(@player_header_regex, header_line)
    current = String.to_integer(current)
    max = String.to_integer(max)
    unattended = if Enum.empty?(ops), do: Enum.count(non_ops), else: 0

    [
      "Players online: #{current} / #{max}",
      if(unattended > 0, do: "(unattended)", else: "")
    ]
    |> Enum.join(" ")
    |> Logger.info()

    [{"ops", ops}, {"non-ops", non_ops}]
    |> Enum.each(fn {name, set} ->
      unless Enum.empty?(set) do
        [
          String.pad_trailing("  - #{Enum.count(set)} #{name}:", 15),
          set |> Enum.sort() |> Enum.join(", ")
        ]
        |> Enum.join(" ")
        |> Logger.info()
      end
    end)

    prefix = "#{state.options.statsd_prefix}.server.players"
    batch.gauge(state.statsd, "#{prefix}.current", current)
    batch.gauge(state.statsd, "#{prefix}.max", max)
    batch.gauge(state.statsd, "#{prefix}.unattended", unattended)
  end
end
