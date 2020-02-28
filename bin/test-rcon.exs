alias Mcscripts.{Options, Rcon}

options = System.argv() |> Options.parse()
IO.puts("Connecting to RCON on #{options.rcon_host}, port #{options.rcon_port} ...")
{:ok, rcon} = Rcon.connect(options.rcon_host, options.rcon_port, options.rcon_password)

IO.puts("Running test ...")
lines = Rcon.command!(rcon, "help") |> String.split("\n")

case Enum.count(lines) do
  1 ->
    IO.puts([
      "\nPROBLEM: Your server seems to have the RCON bug.",
      "\n         All lines of output are combined into a single line,",
      "\n         making it impossible to work with reliably.",
      "\n         Check the README.md for details.\n"
    ])

    exit({:shutdown, 1})

  n when n > 5 ->
    IO.puts("\nEverything looks good!\nYour server is ready for these scripts.\n")

  n ->
    raise "Expected either many lines or a single line, got #{n} lines??"
end
