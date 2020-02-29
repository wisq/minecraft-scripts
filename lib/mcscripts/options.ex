defmodule Mcscripts.Options do
  defstruct(
    # Statsd options:
    statsd_host: "localhost",
    statsd_port: 8125,
    statsd_prefix: "minecraft",

    # RCON options:
    rcon_host: "localhost",
    rcon_port: 25575,
    rcon_password: "",

    # Monitor options:
    minecraft_path: "/home/minecraft/server",
    monitor_interval: 60,
    monitor_lists_interval: 1800,
    monitor_track_players: false,

    # WMB options:
    wmb_cycle: true,
    wmb_cycle_format: "%Y-%m-%d.%H",
    wmb_stats: true,
    wmb_backup_path: "/home/minecraft/backups",
    wmb_config_file: "${wmb_backup_path}/wmb.yml",
    wmb_log_file: "${wmb_backup_path}/wmb.log",
    wmb_upload_target: "${wmb_backup_path}/upload/",
    # WMB paths:
    wmb_path: "/home/minecraft/wmb",
    wmb_bin_cycle: "${wmb_path}/bin/cycle",
    wmb_bin_sync: "${wmb_path}/bin/sync"
  )

  @special_options [
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
      {:integer, "How often (in seconds) to reload player lists (ops, whitelist)"},
    monitor_track_players: {:boolean, "Record online status of every player in whitelist"}
  ]
  @wmb_options [
    wmb_cycle: {:boolean, "Perform a WMB `cycle` command before backups"},
    wmb_cycle_format:
      {:string, "Format for WMB `cycle` directories (using `strftime` placeholders)"},
    wmb_stats: {:boolean, "Collect stats regarding backup size on disk"},
    wmb_backup_path: {:string, "Path to WMB backups"},
    wmb_config_file: {:string, "Path to WMB config file"},
    wmb_upload_target: {:string, "rsync target for WMB sync"},
    wmb_path: {:string, "Path to WMB installation (with `bin/cycle`, `bin/sync`, etc)"}
  ]

  def parse(args, features \\ []) do
    config_options =
      [
        if(Keyword.get(features, :statsd, true), do: @statsd_options),
        if(Keyword.get(features, :rcon, true), do: @rcon_options),
        if(Keyword.get(features, :monitor, false), do: @monitor_options),
        if(Keyword.get(features, :wmb, false), do: @wmb_options)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.concat()

    all_options = Enum.concat(@special_options, config_options)
    strict = Enum.map(all_options, fn {opt, {type, _doc}} -> {opt, type} end)

    args = Enum.concat(args_from_environment(config_options), args)

    case OptionParser.parse(args, strict: strict) do
      {parsed, [], []} ->
        parsed

      {_, _, [{badopt, nil} | _]} ->
        usage("Unknown option: #{inspect(badopt)}", all_options)

      {_, _, [{opt, badvalue} | _]} ->
        type = get_option_type(all_options, opt)

        usage(
          "Expected #{type} for #{inspect(opt)} option, got #{inspect(badvalue)}",
          all_options
        )

      {_, [badarg | _], []} ->
        usage("Unexpected non-option argument: #{inspect(badarg)}", all_options)
    end
    |> check_help(all_options)
    |> apply_substitutions()
  end

  defp get_option_type(options, opt) do
    key = option_to_atom(opt)
    {type, _} = Keyword.fetch!(options, key)
    type
  end

  defp args_from_environment(options) do
    env = System.get_env()

    options
    |> Enum.map(fn {opt, _} ->
      var = opt |> Atom.to_string() |> String.upcase()

      case Map.fetch(env, var) do
        {:ok, value} ->
          opt = atom_to_option(opt)
          "#{opt}=#{value}"

        :error ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp check_help(options, all_options) do
    {help, options} = Keyword.pop(options, :help, false)
    if help, do: usage(nil, all_options)
    options
  end

  @env_help_text """
  You can also set any of the above (except special options like `--help`)
  using environment variables.  For example,

      RCON_PASSWORD=some_password mix run bin/script.exs

  or

      export RCON_PASSWORD=some_password
      mix run bin/script.exs

  (So if a script is complaining about an option you didn't set
  on the command line, check your environment variables.)
  """

  defp usage(nil, all_options) do
    IO.puts(:stderr, [
      "\nAvailable options:\n\n",
      option_documentation(all_options),
      "\n\n#{@env_help_text}"
    ])

    exit(:normal)
  end

  defp usage(error, all_options) do
    IO.puts(:stderr, [
      "\nAvailable options:\n\n",
      option_documentation(all_options),
      "\n\nERROR: #{error}"
    ])

    exit({:shutdown, 1})
  end

  defp atom_to_option(opt) do
    "--" <>
      (opt
       |> Atom.to_string()
       |> String.replace("_", "-"))
  end

  defp option_to_atom("--" <> opt) do
    opt
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp option_documentation(all_options) do
    defaults = %__MODULE__{}

    all_options
    |> Enum.map(fn {key, {type, doc}} ->
      opt = atom_to_option(key)

      basic =
        case type do
          :boolean -> "#{opt}\n\t#{doc}"
          _ -> "#{opt} (#{type})\n\t#{doc}"
        end

      case Map.fetch(defaults, key) do
        :error -> basic
        {:ok, default} -> "#{basic}\n\tDefault: #{inspect(default)}"
      end
    end)
    |> Enum.map(&"    #{&1}")
    |> Enum.intersperse("\n\n")
  end

  defp apply_substitutions(options) do
    options = struct!(__MODULE__, options)

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
