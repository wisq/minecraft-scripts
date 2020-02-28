defmodule Mcscripts.Stats do
  use GenServer
  require Logger
  alias Mcscripts.{Options, Rcon}

  import Mcscripts.Stats.{ForgeTiming, Players}

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
