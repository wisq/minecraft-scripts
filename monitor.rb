#!/usr/bin/ruby

require 'pathname'
require 'set'
require 'bundler'
Bundler.require

$stdout.sync = $stderr.sync = true

DEBUG = false

STATSD_PREFIX = 'minecraft.server'

SV      = Pathname.new('/etc/service/minecraft')
CONTROL = SV + 'input'
SV_LOG  = SV + 'log/main/current'

MC_PATH   = Pathname.new('/home/minecraft/current')
WHITELIST = MC_PATH + 'white-list.txt'
OPS       = MC_PATH + 'ops.txt'

COMMANDS = [
  'forge tps',
  'list'
]

def refresh_lists
  return if $refresh_time && (Time.now - $refresh_time) < 300
  $whitelist = WHITELIST.read.lines.map(&:chomp).to_set
  $ops = OPS.read.lines.map(&:chomp).to_set
  $refresh_time = Time.now
end

def whitelisted_players
  refresh_lists
  $whitelist
end

def ops_players
  refresh_lists
  $ops
end

statsd = Statsd.new

tail_fh = IO.popen(
  ['tail', '-n', '0', '-F', SV_LOG.to_s],
  :err => ['/dev/null', 'w']
)

control = CONTROL.open('a')
control.sync = true

Thread.abort_on_exception = true
command_thread = Thread.new do
  sleep(1)
  loop do
    COMMANDS.each do |cmd|
      control.puts(cmd)
      sleep(60.0 / COMMANDS.length)
    end
  end
end

next_line = nil
tail_fh.each_line do |line|
  statsd.increment('minecraft.server.log')

  current_line = next_line
  next_line = nil

  unless line =~ /^[0-9_:\.-]+ [0-9-]+ [0-9:]+ \[([A-Z]+)\] \[Minecraft-Server\] /
    puts "Unknown line: #{line.inspect}" if DEBUG
    next
  end

  priority, message = $1, $'
  next if message.start_with?('<') # people chatting, don't want them to spoof us

  message.chomp!

  if message =~ /^(?:Dim (-?\d+)|Overall) : Mean tick time: (\d+\.\d+) ms. Mean TPS: (\d+\.\d+)$/
    dimension, tick_ms, tps = $1, $2, $3

    if dimension
      options = {:tags => ["dimension:#{dimension}"]}
      statsd.gauge('minecraft.server.tick.ms',  tick_ms, options)
      statsd.gauge('minecraft.server.tick.tps', tps,     options)
    end

    printf(
      "%s: %.2f ms, %.2f tps\n",
      dimension ? "Dimension #{dimension}" : "Overall",
      tick_ms, tps)
  elsif message =~ /^There are (\d+)\/(\d+) players online:$/
    current, max = $1, $2
    statsd.gauge('minecraft.server.players.current', current)
    statsd.gauge('minecraft.server.players.max',     max)
    next_line = :players
    puts "#{current} of #{max} players online."
  elsif current_line == :players
    online = message.downcase.split(', ').to_set
    whitelisted = whitelisted_players
    ops_online = online & ops_players

    whitelisted.each do |name|
      statsd.gauge('minecraft.server.players', online.include?(name) ? 1 : 0, :tags => ["name:#{name}"])
    end

    puts "Online:  #{online.sort.join(', ')}"
    puts "Offline: #{(whitelisted - online).sort.join(', ')}"
    puts "Ops:     #{ops_online.sort.join(', ')}" unless ops_online.empty?

    # I use an alert on this so I know if my friends are playing while I'm not around. :)
    statsd.gauge('minecraft.server.players.unattended', ops_online.empty? ? online.count : 0)
  else
    puts "Unknown message: #{message.inspect}" if DEBUG
  end
end
