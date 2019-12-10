module Resqued
  class MasterState
    def initialize
      @listeners_created = 0
      @listener_states = {}
    end

    # Public: When starting fresh, from command-line options, assign the initial values.
    def init(options)
      @config_paths = options.fetch(:config_paths)
      @exec_on_hup  = options.fetch(:exec_on_hup) { false }
      @fast_exit    = options.fetch(:fast_exit) { false }
      @pidfile      = options.fetch(:master_pidfile) { nil }
    end

    attr_reader :config_paths
    attr_accessor :current_listener_pid
    attr_reader :exec_on_hup
    attr_reader :fast_exit
    attr_accessor :last_good_listener_pid
    attr_accessor :listeners_created
    attr_reader :listener_states
    attr_accessor :paused
    attr_reader :pidfile
  end
end
