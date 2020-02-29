defmodule Mcscripts.Stats.ForgeTiming do
  require Logger
  alias Mcscripts.Rcon

  def collect_forge_timing(state, batch) do
    Rcon.command!(state.rcon, "forge tps")
    |> String.split("\n")
    |> Enum.each(&record_forge_timing(&1, state, batch))
  end

  @dimension_regex ~r{^Dim \s+ (?<num>-?\d+) \s+ \( (?<name>[^\(\)]+) \)$}x

  defp record_forge_timing(line, state, batch) do
    case String.split(line, " : ", parts: 2) do
      ["Overall", timing] ->
        record_forge_timing(nil, nil, timing, state, batch)

      [dimension, timing] ->
        %{"num" => num, "name" => name} = Regex.named_captures(@dimension_regex, dimension)
        record_forge_timing(num, name, timing, state, batch)
    end
  end

  defp record_forge_timing(number, name, line, state, batch) do
    prefix = "#{state.options.statsd_prefix}.server"

    timings =
      line
      |> String.split(". ")
      |> Map.new(fn item ->
        [key, value] = String.split(item, ": ", parts: 2)
        {key, value}
      end)

    tick_ms =
      Map.fetch!(timings, "Mean tick time")
      |> String.replace(~r{ ms$}, "")
      |> check_is_decimal()

    tps =
      Map.fetch!(timings, "Mean TPS")
      |> check_is_decimal()

    desc = "#{tps} TPS at #{tick_ms} ms/tick"

    case number do
      nil ->
        Logger.info("Overall: #{desc}.")
        batch.gauge(state.statsd, "#{prefix}.tick.ms.overall", tick_ms)
        batch.gauge(state.statsd, "#{prefix}.tick.tps.overall", tps)

      n ->
        tags = ["dimension:#{n}"]
        Logger.info("Dimension #{inspect(name)} (#{number}): #{desc}.")
        batch.gauge(state.statsd, "#{prefix}.tick.ms", tick_ms, tags: tags)
        batch.gauge(state.statsd, "#{prefix}.tick.tps", tps, tags: tags)
    end
  end

  defp check_is_decimal(str) do
    unless String.match?(str, ~r{^\d+\.\d+$}), do: raise("Can't parse decimal: #{inspect(str)}")
    str
  end
end
