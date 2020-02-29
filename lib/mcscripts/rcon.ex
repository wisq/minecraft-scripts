defmodule Mcscripts.Rcon do
  use GenServer

  def connect(host, port, password) do
    GenServer.start_link(__MODULE__, {host, port, password})
  end

  defp command(rcon, command) do
    GenServer.call(rcon, {:command, command})
  end

  def command!(rcon, command) do
    {:ok, output} = command(rcon, command)
    output
  end

  @impl true
  def init({host, port, password}) do
    {:ok, conn} = RCON.Client.connect(host, port)
    {:ok, conn, true} = RCON.Client.authenticate(conn, password)
    {:ok, conn}
  end

  @impl true
  def handle_call({:command, command}, _, conn) do
    {result, conn, output} = RCON.Client.exec(conn, command, single_packet: true)
    {:reply, {result, output}, conn}
  end
end
