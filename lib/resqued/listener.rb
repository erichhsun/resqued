require 'socket'

require 'resqued/config'
require 'resqued/logging'
require 'resqued/procline_version'
require 'resqued/runtime_info'
require 'resqued/sleepy'
require 'resqued/version'
require 'resqued/worker'

module Resqued
  # A listener process. Watches resque queues and forks workers.
  class Listener
    include Resqued::Logging
    include Resqued::ProclineVersion
    include Resqued::Sleepy

    # Configure a new listener object.
    #
    # Runs in the master process.
    def initialize(options)
      @config_paths    = options.fetch(:config_paths)
      @old_workers     = options.fetch(:old_workers) { [] }.freeze
      @socket          = options.fetch(:socket)
      @listener_id     = options.fetch(:listener_id) { nil }
    end

    # Public: As an alternative to #run, exec a new ruby instance for this listener.
    #
    # Runs in the master process.
    def exec
      socket_fd = @socket.to_i
      ENV['RESQUED_SOCKET']      = socket_fd.to_s
      ENV['RESQUED_CONFIG_PATH'] = @config_paths.join(':')
      ENV['RESQUED_STATE']       = (@old_workers.map { |r| "#{r[:pid]}|#{r[:queue]}" }.join('||'))
      ENV['RESQUED_LISTENER_ID'] = @listener_id.to_s
      ENV['RESQUED_MASTER_VERSION'] = Resqued::VERSION
      log "exec: #{Resqued::START_CTX['$0']} listener"
      Kernel.exec(Resqued::START_CTX['$0'], 'listener', socket_fd => socket_fd) # The hash at the end only works in new-ish (1.9+ or so) rubies. It's required for ruby 2.0.
    end

    # Public: Given args from #exec, start this listener.
    def self.exec!
      options = {}
      if socket = ENV['RESQUED_SOCKET']
        options[:socket] = Socket.for_fd(socket.to_i)
      end
      if path = ENV['RESQUED_CONFIG_PATH']
        options[:config_paths] = path.split(':')
      end
      if state = ENV['RESQUED_STATE']
        options[:old_workers] = state.split('||').map { |s| Hash[[:pid,:queue].zip(s.split('|'))] }
      end
      if listener_id = ENV['RESQUED_LISTENER_ID']
        options[:listener_id] = listener_id
      end
      new(options).run
    end

    SIGNALS = [ :CONT, :QUIT, :INT, :TERM ]
    ALL_SIGNALS = SIGNALS + [ :CHLD ]

    SIGNAL_QUEUE = []

    # Public: Run the main loop.
    def run
      trap(:CHLD) { awake }
      SIGNALS.each { |signal| trap(signal) { SIGNAL_QUEUE << signal ; awake } }
      @socket.close_on_exec = true
      write_procline('starting')

      config = Resqued::Config.new(@config_paths)
      set_default_resque_logger
      config.before_fork(info)
      report_to_master("RUNNING")

      write_procline('running')
      init_workers(config)
      exit_signal = run_workers_run

      write_procline('shutdown')
      burn_down_workers(exit_signal || :QUIT)
    end

    # Private.
    def set_default_resque_logger
      require 'resque'
      if Resque.respond_to?('logger=')
        Resque.logger = Resqued::Logging.build_logger
      end
    end

    # Private.
    def run_workers_run
      loop do
        reap_workers(Process::WNOHANG)
        check_for_expired_workers
        start_idle_workers
        case signal = SIGNAL_QUEUE.shift
        when nil
          yawn
        when :CONT
          kill_all(signal)
        when :QUIT, :INT, :TERM
          return signal
        end
      end
    end

    # Private: make sure all the workers stop.
    #
    # Resque workers have gaps in their signal-handling ability.
    def burn_down_workers(signal)
      loop do
        check_for_expired_workers
        write_procline('shutdown')
        SIGNAL_QUEUE.clear

        break if :no_child == reap_workers(Process::WNOHANG)
        kill_all(signal)

        sleep 1 # Don't kill any more often than every 1s.
        yawn 5
      end
      # One last time.
      reap_workers
    end

    # Private: send a signal to all the workers.
    def kill_all(signal)
      idle, running = partition_workers
      log "kill -#{signal} #{running.map { |r| r.pid }.inspect}"
      running.each { |worker| worker.kill(signal) }
    end

    # Private: all available workers
    attr_reader :workers

    # Private: just the running workers.
    def running_workers
      partition_workers.last
    end

    # Private: Split the workers into [not-running, running]
    def partition_workers
      workers.partition { |worker| worker.idle? }
    end

    # Private.
    def yawn(sleep_time = nil)
      sleep_time ||=
        begin
          sleep_times = [60.0] + workers.map { |worker| worker.backing_off_for }
          [sleep_times.compact.min, 0.0].max
        end
      super(sleep_time, @socket)
    end

    # Private: Check for workers that have stopped running
    def reap_workers(waitpidflags = 0)
      loop do
        worker_pid, status = Process.waitpid2(-1, waitpidflags)
        if worker_pid.nil?
          return :none_ready
        elsif status.exited?
          log "Worker exited #{status}"
          finish_worker(worker_pid, status)
          report_to_master("-#{worker_pid}")
        else
          log "Worker reported #{status}"
        end
      end
    rescue Errno::ECHILD
      # All done
      :no_child
    end

    # Private: Check if master reports any dead workers.
    def check_for_expired_workers
      loop do
        IO.select([@socket], nil, nil, 0) or return
        line = @socket.readline
        finish_worker(line.to_i, nil)
      end
    rescue EOFError
      log "eof from master"
      Process.kill(:QUIT, $$)
    end

    # Private.
    def finish_worker(worker_pid, status)
      workers.each do |worker|
        if worker.pid == worker_pid
          worker.finished!(status)
        end
      end
    end

    # Private.
    def start_idle_workers
      workers.each do |worker|
        if worker.idle?
          worker.try_start
          if pid = worker.pid
            report_to_master("+#{pid},#{worker.queue_key}")
          end
        end
      end
    end

    # Private.
    def init_workers(config)
      @workers = config.build_workers
      @old_workers.each do |running_worker|
        if blocked_worker = @workers.detect { |worker| worker.idle? && worker.queue_key == running_worker[:queue] }
          blocked_worker.wait_for(running_worker[:pid].to_i)
        end
      end
    end

    # Private: Report child process status.
    #
    # Examples:
    #
    #     report_to_master("+12345,queue")  # Worker process PID:12345 started, working on a job from "queue".
    #     report_to_master("-12345")        # Worker process PID:12345 exited.
    def report_to_master(status)
      @socket.puts(status)
    rescue Errno::EPIPE
      Process.kill(:QUIT, $$) # If the master is gone, LIFE IS NOW MEANINGLESS.
    end

    # Private.
    def write_procline(status)
      procline = "#{procline_version} listener"
      procline << " #{@listener_id}" if @listener_id
      procline << " [#{info.app_version}]" if info.app_version
      procline << " [#{status}]"
      procline << " [#{running_workers.size} workers]" if status == 'shutdown'
      procline << " #{@config_paths.join(' ')}"
      $0 = procline
    end

    # Private.
    def info
      @info ||= RuntimeInfo.new
    end
  end
end
