defmodule Mcscripts.Backup do
  alias Mcscripts.{Options, Rcon}
  require DogStatsd

  def run(%Options{} = options) do
    {:ok, statsd} = DogStatsd.new(options.statsd_host, options.statsd_port)
    {:ok, rcon} = Rcon.connect(options.rcon_host, options.rcon_port, options.rcon_password)

    DogStatsd.time statsd, "#{options.statsd_prefix}.backup.time.total" do
      wmb_cycle(options)

      try do
        DogStatsd.time statsd, "#{options.statsd_prefix}.backup.time.save" do
          Rcon.command!(rcon, "save-all flush")
        end

        Rcon.command!(rcon, "save-off")

        DogStatsd.time statsd, "#{options.statsd_prefix}.backup.time.sync" do
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
end
