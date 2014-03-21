#!/usr/bin/env ruby

raise "Ruby 1.9.3 required" unless RUBY_VERSION >= '1.9.3'

class Wrapper
  class ReloadSignal < Exception; end

  def initialize(*args)
    fifo, chdir, *@command = args
    @fifo_path  = File.expand_path(fifo)
    @chdir_path = File.expand_path(chdir)
  end

  def run
    raise "FIFO not found: #{@fifo_path.inspect}" unless File.pipe?(@fifo_path)
    raise "Cannot read FIFO: #{@fifo_path.inspect}" unless File.readable?(@fifo_path)

    @reader, @writer = IO.pipe

    @pid = fork do
      @writer.close
      STDIN.reopen(@reader)

      log "Changing directory: #{@chdir_path.inspect}"
      Dir.chdir(@chdir_path)
      log "Executing: #{@command.inspect}"
      exec(*@command)
    end
    sleep(1)

    @reader.close
    register_signal_handlers

    @proxy = Thread.new { proxy_thread }
    wait_loop
  end

  private

  def log(msg)
    $stdout.puts "[wrap.rb:#{$$}] #{msg}"
    $stdout.flush
  end

  def register_signal_handlers
    private_methods.each do |method|
      if method.to_s =~ /^handle_(sig[a-z0-9]+)$/
        signal = $1.upcase
        log "Registering signal handler: #{method} (#{signal})"
        Signal.trap(signal) { send(method, signal) }
      end
    end
  end

  def proxy_thread
    loop do
      File.open(@fifo_path) do |fh|
        begin
          fh.each_line do |line|
            line.chomp!
            log "Received command: #{line.inspect}"
            @writer.puts(line)
          end
        rescue StandardError => e
          log "Proxy: #{e.message} (#{e.class})"
        end
      end
    end
  rescue Exception => e
    log "Unhandled error in proxy thread: #{e.message} (#{e.class})"
  end

  def wait_loop
    until Process.wait(@pid)
      sleep(1)
    end
    if $?.success?
      log "Server has shut down."
    else
      log "Server died: #{$?.inspect}"
      sleep(15)
    end
  end

  def wait_for_exit(secs)
    (1..secs).each do |i|
      sleep(1)
      return true if Process.wait(@pid, Process::WNOHANG)
    end

    return false
  end

  def handle_sigint(signal)
    handle_sigterm(signal)
  end

  def handle_sigterm(signal)
    return log "Received #{signal} but shutdown is already in progress." if @shutdown
    @shutdown = true

    log "Received #{signal}, attempting graceful stop."
    @writer.puts("/stop")

    unless wait_for_exit(30)
      log "Server not shutting down, issuing SIGTERM."
      Process.kill('TERM', @pid)

      unless wait_for_exit(30)
        log "Server not responding to SIGTERM, issuing SIGKILL."
        Process.kill('kill', @pid)

        unless wait_for_exit(30)
          log "Unable to kill process #{@pid.inspect}, giving up."
          exit(1)
        end
      end
    end

    log "Server successfully shut down."
    exit(0)
  rescue StandardError => e
    log "Signal handler got error: #{e.inspect}"
    exit(1)
  ensure
    @shutdown = false
  end

  def handle_sighup(signal)
    log "Received #{signal}, restarting proxy thread."
    @proxy.raise(ReloadSignal) if @proxy.alive?
    sleep(1)
    @proxy.kill if @proxy.alive?

    log "Launching new proxy."
    @proxy = Thread.new { proxy_thread }
  end

  def handle_sigusr1(signal)
    log "Received #{signal}, disabling disk saves."
    @writer.puts("/save-off")
  end

  def handle_sigusr2
    log "Received #{signal}, enabling disk saves."
    @writer.puts("/save-on")
  end
end

Wrapper.new(*ARGV).run
