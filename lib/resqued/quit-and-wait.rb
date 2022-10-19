require "optparse"

module Resqued
  class QuitAndWait
    def self.exec!(argv)
      options = {grace_seconds: 30}

      opts = OptionParser.new do |opts|
        opts.banner = <<USAGE
Usage: resqued quit-and-wait PIDFILE [--grace-period SECONDS]

Use this as a preStop script in kubernetes. This script will send a SIGQUIT to
resqued immediately, and then sleep until either resqued exits or until the
grace period is approximately 5 seconds from expiration. This script exits 0 if
resqued exited and 99 otherwise.
USAGE

        opts.on "-h", "--help", "Show this message" do
          puts opts
          exit
        end

        opts.on "-v", "--version", "Show the version" do
          require "resqued/version"
          puts Resqued::VERSION
          exit
        end

        opts.on "--grace-period SECONDS", Numeric, "If resqued does not exit within SECONDS (default 15) seconds, exit with an error" do |v|
          options[:grace_seconds] = v
        end
      end

      argv = opts.parse(argv)
      if argv.size != 1
        puts opts
        exit 1
      end
      options[:pidfile] = argv.shift

      new(**options).exec!
    end

    def initialize(grace_seconds:, pidfile:)
      @grace_seconds = grace_seconds
      @pidfile = pidfile
    end

    attr_reader :grace_seconds, :pidfile

    def exec!
      start = Time.now
      stop_at = start + grace_seconds - 5
      pid = File.read(pidfile).to_i

      log "kill -QUIT #{pid} (resqued-master)"
      Process.kill(:QUIT, pid)

      while Time.now < stop_at
        begin
          # check if pid is still alive.
          Process.kill(0, pid)
        rescue Errno::ESRCH # no such process, it exited!
          log "ok: resqued-master with pid #{pid} exited"
          exit 0
        end
      end

      log "giving up, resqued-master with pid #{pid} is still running."
      exit 99
    end

    def log(message)
      puts "#{Time.now.strftime("%H:%M:%S.%L")} #{message}"
    end
  end
end
