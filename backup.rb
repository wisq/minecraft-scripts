#!/usr/bin/ruby

require 'pathname'
require 'bundler'
Bundler.require

STATSD_PREFIX = 'minecraft.backup'

HOME    = Pathname.new('/home/minecraft')
WMB     = HOME + 'wmb'
BACKUPS = HOME + 'backups/current'

SV      = Pathname.new('/etc/service/minecraft')
CONTROL = SV + 'input'
SV_LOG  = SV + 'log/main/current'

statsd = Statsd.new

tail_read, tail_write = IO.pipe
tail = Process.spawn(
  '/usr/bin/tail', '-n', '0', '-F', SV_LOG.to_s,
  :out => tail_write,
  :err => ['/dev/null', 'w']
)
sleep(1)

statsd.time("#{STATSD_PREFIX}.time.total") do
  control = CONTROL.open('a')
  control.sync = true
  control.puts('say ** Backup starting, please stand by ... **')

  begin
    system("#{WMB}/bin/cycle", BACKUPS.to_s, '%Y-%m-%d.%H')
    raise 'WMB cycle failed' unless $?.success?

    statsd.time("#{STATSD_PREFIX}.time.save") do
      control.puts('save-all')
      tail_read.each_line do |line|
        break if line.include?('[Minecraft-Server] Saved the world')
      end
    end

    control.puts('save-off')
    tail_read.each_line do |line|
      break if line.include?('[Minecraft-Server] Turned off world auto-saving')
    end

    statsd.time("#{STATSD_PREFIX}.time.sync") do
      system(
        "#{WMB}/bin/sync", "#{BACKUPS}/wmb.yml",
        "#{BACKUPS}/upload/", "#{BACKUPS}/wmb.log"
      )
      raise 'WMB sync failed' unless $?.success?
    end

    control.puts('say ** Backup complete, enjoy! **')
  rescue Exception => e
    control.puts('say ** Backup FAILED; please contact admin! **')
    control.puts("say ** #{e.message} **")
  ensure
    control.puts('save-on')
  end
end

prior   = "#{BACKUPS}/upload/prior/"
current = "#{BACKUPS}/upload/current/"
IO.popen(['/usr/bin/du', '-s', '--block-size=1', prior, current]) do |fh|
  fh.each_line do |line|
    size, path = line.chomp.split("\t")
    statsd.gauge("#{STATSD_PREFIX}.size.incremental", size) if path == current
  end
end

IO.popen(['/usr/bin/du', '-s', '--block-size=1', BACKUPS.to_s]) do |fh|
  size, path = fh.read.chomp.split("\t")
  statsd.gauge("#{STATSD_PREFIX}.size.total", size)
end
