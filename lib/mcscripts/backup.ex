defmodule Mcscripts.Backup do
  alias Mcscripts.{Options, Rcon}
  require Logger
  require DogStatsd

  def run(%Options{} = options) do
    {:ok, statsd} = DogStatsd.new(options.statsd_host, options.statsd_port)
    {:ok, rcon} = Rcon.connect(options.rcon_host, options.rcon_port, options.rcon_password)
    prefix = "#{options.statsd_prefix}.backup"

    DogStatsd.time statsd, "#{prefix}.time.total" do
      wmb_cycle(options)

      try do
        DogStatsd.time statsd, "#{prefix}.time.save" do
          Rcon.command!(rcon, "save-all flush")
        end

        Rcon.command!(rcon, "save-off")

        DogStatsd.time statsd, "#{prefix}.time.sync" do
          wmb_sync(options)
        end
      rescue
        err ->
          Rcon.command!(rcon, "say ** ERROR: Backup failed!  Please let an admin know ASAP! **")
          raise err
      after
        Rcon.command!(rcon, "save-on")
      end
    end

    collect_stats(options, statsd, prefix)
  end

  defp wmb_cycle(%Options{wmb_cycle: false}), do: :noop

  defp wmb_cycle(%Options{wmb_cycle: true} = options) do
    options.wmb_backup_path
    |> Path.join("upload")
    |> File.mkdir_p()

    System.cmd(
      options.wmb_bin_cycle,
      [
        options.wmb_backup_path,
        options.wmb_cycle_format
      ]
    )
    |> check_wmb_result("WMB cycle")
  end

  defp wmb_sync(%Options{} = options) do
    System.cmd(
      options.wmb_bin_sync,
      [
        options.wmb_config_file,
        options.wmb_upload_target,
        options.wmb_log_file
      ]
    )
    |> check_wmb_result("WMB sync")
  end

  defp check_wmb_result({_output, 0}, _title), do: :ok

  defp check_wmb_result({output, code}, title) do
    formatted =
      output
      |> String.split("\n")
      |> Enum.map(&">> #{&1}")
      |> Enum.join("\n")

    raise RuntimeError, message: "#{title} failed:\n\n#{formatted}\n\nExited with code #{code}."
  end

  defp collect_stats(%Options{wmb_stats: false}, _, _), do: :noop

  defp collect_stats(%Options{wmb_stats: true} = options, statsd, prefix) do
    backups = options.wmb_backup_path
    prior = "#{backups}/upload/prior/"
    current = "#{backups}/upload/current/"

    DogStatsd.batch(statsd, fn batch ->
      if File.dir?(prior) do
        stats_incremental("#{prefix}.size.incremental", prior, current, statsd, batch)
      else
        Logger.warn("No prior directory #{inspect(prior)}; will not collect incremental stats.")
      end

      stats_total("#{prefix}.size.latest", "Latest backup", current, statsd, batch)
      stats_total("#{prefix}.size.all", "All backups", backups, statsd, batch)
    end)
  end

  defp stats_incremental(metric, prior, current, statsd, batch) do
    {output, 0} = System.cmd("du", ["-s", "--block-size=1", prior, current])
    [_, ^prior, bytes, ^current, ""] = String.split(output, ~r{[\t\n]})
    bytes = String.to_integer(bytes)

    Logger.info("Incremental backup size: #{format_bytes(bytes)}")
    batch.gauge(statsd, metric, bytes)
  end

  defp stats_total(metric, title, path, statsd, batch) do
    {output, 0} = System.cmd("du", ["-s", "--block-size=1", path])
    [bytes, ^path, ""] = String.split(output, ~r{[\t\n]})
    bytes = String.to_integer(bytes)

    Logger.info("#{title} size: #{format_bytes(bytes)}")
    batch.gauge(statsd, metric, bytes)
  end

  defp format_bytes(number) do
    delimited =
      number
      |> Integer.to_string()
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.chunk_every(3)
      |> Enum.intersperse(',')
      |> Enum.concat()
      |> List.to_string()
      |> String.reverse()

    "#{delimited} bytes"
  end
end
