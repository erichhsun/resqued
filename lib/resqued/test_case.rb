require "resqued/config"
require "resqued/runtime_info"

module Resqued
  module TestCase
    module LoadConfig
      # Test your resqued config.
      #
      # If you do this to start resqued:
      #
      #     $ resqued config/resqued-environment.rb config/resqued-workers.rb
      #
      # Then you'll want to do this in a test:
      #
      #     assert_resqued 'config/resqued-environment.rb', 'config/resqued-workers.rb'
      def assert_resqued(*paths)
        config = Resqued::Config.new(paths)
        config.before_fork(RuntimeInfo.new)
        config.build_workers
        config.after_fork(FakeWorker.new)
      end
    end

    Default = LoadConfig

    include Default

    class FakeWorker
      def initialize
      end
    end
  end
end
