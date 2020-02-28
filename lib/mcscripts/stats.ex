defmodule Mcscripts.Stats do
  use GenServer
  require Logger
  alias Mcscripts.{Options, Rcon}

  defmodule State do
    @enforce_keys [:options, :statsd, :rcon]
    Enum.concat(
      @enforce_keys |> Enum.map(fn key -> {key, nil} end),
      ops: MapSet.new(),
      whitelist: MapSet.new()
    )
    |> defstruct()
  end

  def run(%Options{} = options) do
    {:ok, _pid} = GenServer.start_link(__MODULE__, options)
    Process.sleep(:infinity)
  end

  @impl true
  def init(%Options{} = options) do
    {:ok, statsd} = DogStatsd.new(options.statsd_host, options.statsd_port)
    {:ok, rcon} = Rcon.connect(options.rcon_host, options.rcon_port, options.rcon_password)

    state =
      %State{
        options: censor_options(options),
        statsd: statsd,
        rcon: rcon
      }
      |> refresh_lists()

    queue_refresh_lists(state)
    queue_collect_stats(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:refresh_lists, state) do
    queue_refresh_lists(state)
    {:noreply, refresh_lists(state)}
  end

  @impl true
  def handle_info(:collect_stats, state) do
    collect_stats(state)
    queue_collect_stats(state)
    {:noreply, state}
  end

  defp censor_options(options) do
    struct!(
      Options,
      options
      |> Map.from_struct()
      |> Enum.map(fn {key, value} ->
        cond do
          is_binary(value) and String.contains?(Atom.to_string(key), "password") ->
            {key, String.replace(value, ~r{.}, "*")}

          true ->
            {key, value}
        end
      end)
    )
  end

  defp collect_stats(state) do
    DogStatsd.batch(state.statsd, fn batch ->
      collect_forge_timing(state, batch)
      collect_player_list(state, batch)
    end)
  end

  defp collect_forge_timing(state, batch) do
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
      |> IO.inspect()

    tick_ms =
      Map.fetch!(timings, "Mean tick time")
      |> String.replace(~r{ ms$}, "")
      |> check_is_decimal()

    tps =
      Map.fetch!(timings, "Mean TPS")
      |> check_is_decimal()

    desc = describe_timing(tick_ms, tps)

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

  def describe_timing(tick_ms, tps), do: "#{tps} TPS at #{tick_ms} ms/tick"

  defp check_is_decimal(str) do
    unless String.match?(str, ~r{^\d+\.\d+$}) do
      raise "Can't parse decimal: #{inspect(str)}"
    end

    str
  end

  @player_header_regex ~r{^There are (?<cur>\d+)/(?<max>\d+) players online:$}

  defp collect_player_list(state, batch) do
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

  defp refresh_lists(state) do
    state
    |> read_ops()
    |> read_whitelist()
  end

  defp read_ops(state) do
    %State{state | ops: read_json_list("#{state.options.minecraft_path}/ops.json")}
  end

  defp read_whitelist(state) do
    %State{state | whitelist: read_json_list("#{state.options.minecraft_path}/whitelist.json")}
  end

  defp read_json_list(path) do
    set =
      File.read!(path)
      |> Poison.decode!()
      |> MapSet.new(&Map.fetch!(&1, "name"))

    Logger.info("Loaded #{Enum.count(set)} entries from #{inspect(path)}.")
    set
  end

  defp queue_collect_stats(%State{options: %Options{monitor_interval: secs}}) do
    Process.send_after(self(), :collect_stats, secs * 1000)
  end

  defp queue_refresh_lists(%State{options: %Options{monitor_lists_interval: secs}}) do
    Process.send_after(self(), :refresh_lists, secs * 1000)
  end
end
