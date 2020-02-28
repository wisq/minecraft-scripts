defmodule Mcscripts.Options do
  defstruct(
    # Statsd options:
    statsd_host: "localhost",
    statsd_port: 8125,
    statsd_prefix: "test.minecraft",

    # RCON options:
    rcon_host: "localhost",
    rcon_port: 25575,
    rcon_password: "",

    # Monitor options:
    minecraft_path: "/home/minecraft/server",
    monitor_interval: 60,
    monitor_lists_interval: 1800,

    # WMB options:
    wmb_cycle: true,
    wmb_cycle_format: "%Y-%m-%d.%H",
    wmb_backup_path: "/home/minecraft/backups",
    wmb_config_file: "${wmb_backup_path}/wmb.yml",
    wmb_log_file: "${wmb_backup_path}/wmb.log",
    wmb_upload_target: "${wmb_backup_path}/upload/",
    # WMB paths:
    wmb_path: "/home/minecraft/wmb",
    wmb_bin_cycle: "${wmb_path}/bin/cycle",
    wmb_bin_sync: "${wmb_path}/bin/sync"
  )

  @core_options [
    help: {:boolean, "This help page"}
  ]
  @statsd_options [
    statsd_host: {:string, "Hostname (or IP) of statsd server"},
    statsd_port: {:integer, "UDP port for statsd server"},
    statsd_prefix: {:string, "Prefix for metrics sent to statsd"}
  ]
  @rcon_options [
    rcon_host: {:string, "Hostname (or IP) of Minecraft server"},
    rcon_port: {:integer, "RCON (TCP) port for Minecraft server"},
    rcon_password: {:string, "RCON password for Minecraft server"}
  ]
  @monitor_options [
    minecraft_path: {:string, "Path to Minecraft server installation"},
    monitor_interval: {:integer, "How often (in seconds) to record server stats"},
    monitor_lists_interval:
      {:integer, "How often (in seconds) to reload player lists (ops, whitelist)"}
  ]
  @wmb_options [
    wmb_cycle: {:boolean, "Should we perform a WMB `cycle` command before backups?"},
    wmb_cycle_format:
      {:string, "Format for WMB `cycle` directories (using `strftime` placeholders)"},
    wmb_backup_path: {:string, "Path to WMB backups"},
    wmb_config_file: {:string, "Path to WMB config file"},
    wmb_upload_target: {:string, "rsync target for WMB sync"},
    wmb_path: {:string, "Path to WMB installation (with `bin/cycle`, `bin/sync`, etc)"}
  ]

  def parse(args, features \\ []) do
    available =
      [
        @core_options,
        if(Keyword.get(features, :statsd, true), do: @statsd_options),
        if(Keyword.get(features, :rcon, true), do: @rcon_options),
        if(Keyword.get(features, :monitor, false), do: @monitor_options),
        if(Keyword.get(features, :wmb, false), do: @wmb_options)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.concat()

    strict = Enum.map(available, fn {opt, {type, _doc}} -> {opt, type} end)

    case OptionParser.parse(args, strict: strict) do
      {parsed, [], []} ->
        parsed

      {_, _, [{badopt, _} | _]} ->
        usage("Unknown option: #{inspect(badopt)}", available)

      {_, [badarg | _], []} ->
        usage("Unexpected non-option arguments: #{inspect(badarg)}", available)
    end
    |> check_help(available)
    |> apply_substitutions()
  end

  defp check_help(options, available) do
    if Keyword.get(options, :help, false) do
      usage(nil, available)
    end

    options
  end

  defp usage(nil, available) do
    IO.puts(:stderr, [
      "\nAvailable options:\n\n",
      option_documentation(available),
      "\n"
    ])

    exit(:normal)
  end

  defp usage(error, available) do
    IO.puts(:stderr, [
      "\nAvailable options:\n\n",
      option_documentation(available),
      "\n\nERROR: #{error}"
    ])

    exit({:shutdown, 1})
  end

  defp option_documentation(available) do
    defaults = %__MODULE__{}

    available
    |> Enum.map(fn {key, {type, doc}} ->
      opt = Atom.to_string(key) |> String.replace("_", "-")

      basic =
        case type do
          :boolean -> "--#{opt}\n\t#{doc}"
          _ -> "--#{opt} (#{type})\n\t#{doc}"
        end

      case Map.fetch(defaults, key) do
        :error -> basic
        {:ok, default} -> "#{basic}\n\tDefault: #{inspect(default)}"
      end
    end)
    |> Enum.map(&"    #{&1}")
    |> Enum.intersperse("\n\n")
  end

  defp apply_substitutions(args) do
    options = struct!(__MODULE__, args)

    substituted =
      options
      |> Map.from_struct()
      |> Enum.map(fn {key, value} ->
        case value do
          str when is_binary(str) -> {key, substitute(key, value, options)}
          _ -> {key, value}
        end
      end)

    struct!(__MODULE__, substituted)
  end

  defp substitute(key, value, options) do
    Regex.replace(~r/\${([a-z_]+)\}/, value, fn _, sub_key ->
      case Map.fetch(options, String.to_atom(sub_key)) do
        {:ok, sub_value} -> sub_value
        :error -> raise "Unknown substitution ${#{sub_key}} in --#{key}=#{inspect(value)}"
      end
    end)
  end
end
