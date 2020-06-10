defmodule Mcscripts.Stats.Players do
  require Logger
  alias Mcscripts.Rcon

  @regexes [
    ~r{^There are (?<cur>\d+)/(?<max>\d+) players online:\n(?<list>.*)$},
    ~r{^There are (?<cur>\d+) of a max (?<max>\d+) players online: (?<list>.*)$}
  ]

  def collect_player_list(state, batch) do
    %{"cur" => current, "max" => max, "list" => players_list} =
      Rcon.command!(state.rcon, "list")
      |> try_regexes()

    players =
      case players_list do
        "" -> MapSet.new()
        str -> String.split(str, ", ") |> MapSet.new()
      end

    ops = MapSet.intersection(players, state.ops)
    non_ops = MapSet.difference(players, state.ops)

    current = String.to_integer(current)
    max = String.to_integer(max)
    unattended = if Enum.empty?(ops), do: Enum.count(non_ops), else: 0

    log_player_count(current, max, unattended)
    log_player_list("ops", ops)
    log_player_list("non-ops", non_ops)

    prefix = "#{state.options.statsd_prefix}.server.players"
    batch.gauge(state.statsd, "#{prefix}.current", current)
    batch.gauge(state.statsd, "#{prefix}.max", max)
    batch.gauge(state.statsd, "#{prefix}.unattended", unattended)

    if state.options.monitor_track_players, do: track_players(state, players, batch, prefix)
  end

  defp try_regexes(output) do
    Enum.find_value(@regexes, &Regex.named_captures(&1, output))
  end

  defp log_player_count(current, max, 0) do
    Logger.info("Players online: #{current} / #{max}")
  end

  defp log_player_count(current, max, unattended) when unattended > 0 do
    Logger.info("Players online: #{current} / #{max} (unattended)")
  end

  defp log_player_list(type, set) do
    unless Enum.empty?(set) do
      [
        String.pad_trailing("  - #{Enum.count(set)} #{type}:", 15),
        set |> Enum.sort() |> Enum.join(", ")
      ]
      |> Enum.join(" ")
      |> Logger.info()
    end
  end

  defp track_players(state, online_players, batch, prefix) do
    state.whitelist
    |> Enum.each(fn player ->
      is_online =
        case MapSet.member?(online_players, player) do
          true -> 1
          false -> 0
        end

      tags = ["name:#{player}"]
      batch.gauge(state.statsd, "#{prefix}.online", is_online, tags: tags)
    end)
  end
end
