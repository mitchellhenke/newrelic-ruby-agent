# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require 'logger'
require 'stringio'
require 'tempfile'
require 'zlib'

require_relative '../../test_helper'

# The customer's original lambda function that we wrap may live outside
# any namespace.
def customer_lambda_function(event:, context:)
  raise 'Kaboom!' if event.fetch(:simulate_exception, false)

  Logger.new(StringIO.new).info 'Lots of loggers languidly logging lore' if event.fetch(:simulate_logging, false)

  {statusCode: 200, body: 'Running just as fast as we can'}
end

# The customer's original lambda function may live within a namespace
module Willows
  class Wind
    def self.customer_lambda_function(event:, context:)
      {statusCode: 200, body: 'messing about in boats'}
    end
  end
end

# NOTE: additional integration style testing of the wrapping of the
# customer function is also conducted in the newrelic-lambda-layers repo.
module NewRelic::Agent
  class ServerlessHandler
    class ServerlessHandlerTest < Minitest::Test
      def setup
        config_hash = {:'serverless_mode.enabled' => true}
        @test_config = NewRelic::Agent::Configuration::DottedHash.new(config_hash, true)
        NewRelic::Agent.config.add_config_for_testing(@test_config, true)
      end

      def teardown
        NewRelic::Agent.config.remove_config(@test_config)
      end

      # integration style

      def test_the_complete_handoff_from_the_nr_lambda_layer
        context = testing_context
        output = with_output do
          result = handler.invoke_lambda_function_with_new_relic(method_name: :customer_lambda_function,
            event: {Opossum: :Virginia},
            context: context)

          assert_equal 'Running just as fast as we can', result[:body]
        end
        context.verify

        assert_equal 1, output.size
        assert_match(/lambda_function/, output.first)
      end

      def test_rescued_errors_are_noticed
        output = with_output do
          assert_raises RuntimeError do
            handler.invoke_lambda_function_with_new_relic(method_name: :customer_lambda_function,
              event: {simulate_exception: true},
              context: testing_context)
          end
        end

        assert_equal 1, output.size
        assert_match 'Errors/lambda_function', output.first
      end

      def test_log_events_and_reported
        output = with_output do
          handler.invoke_lambda_function_with_new_relic(method_name: :customer_lambda_function,
            event: {simulate_logging: true},
            context: testing_context)
        end

        assert_equal 1, output.size
        assert_match 'languidly', output.first
      end

      def test_customer_function_lives_within_a_namespace
        context = testing_context
        output = with_output do
          result = handler.invoke_lambda_function_with_new_relic(method_name: :customer_lambda_function,
            event: {Toad: :Hall},
            context: context,
            namespace: 'Willows::Wind')

          assert_equal 'messing about in boats', result[:body]
        end
        context.verify

        assert_equal 1, output.size
        assert_match(/lambda_function/, output.first)
      end

      # unit style

      def test_named_pipe_check_true
        skip_unless_minitest5_or_above

        File.stub :exist?, true, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
          File.stub :writable?, true, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
            assert_predicate handler, :use_named_pipe?
          end
        end
      end

      def test_named_pipe_check_false
        skip_unless_minitest5_or_above

        File.stub :exist?, false, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
          File.stub :writable?, false, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
            refute_predicate handler, :use_named_pipe?
          end
        end
      end

      def test_named_pipe_check_result_is_memoized
        skip_unless_minitest5_or_above

        h = handler
        # memoized to true when writable
        File.stub :exist?, true, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
          File.stub :writable?, true, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
            h.send(:use_named_pipe?)
          end
        end
        # memoization is used and fresh File checks are not performed
        File.stub :exist?, false, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
          File.stub :writable?, false, [NewRelic::Agent::ServerlessHandler::NAMED_PIPE] do
            assert_predicate h, :use_named_pipe?
          end
        end
      end

      def test_cold_is_true_only_for_the_first_check
        h = handler

        assert_predicate h, :cold?
        refute_predicate h, :cold?
        refute_predicate h, :cold?
      end

      def test_function_name_uses_env_var
        expected = 'The Zscaler ZIA chime is the worst sound in the world'
        ENV[NewRelic::Agent::ServerlessHandler::LAMBDA_ENVIRONMENT_VARIABLE] = expected

        assert_equal expected, handler.send(:function_name)
      ensure
        ENV.delete(NewRelic::Agent::ServerlessHandler::LAMBDA_ENVIRONMENT_VARIABLE)
      end

      def test_function_name_falls_back_on_a_default
        original_value = ENV[NewRelic::Agent::ServerlessHandler::LAMBDA_ENVIRONMENT_VARIABLE]
        ENV.delete(NewRelic::Agent::ServerlessHandler::LAMBDA_ENVIRONMENT_VARIABLE) if original_value

        assert_equal NewRelic::Agent::ServerlessHandler::FUNCTION_NAME, handler.send(:function_name)
      ensure
        ENV[NewRelic::Agent::ServerlessHandler::LAMBDA_ENVIRONMENT_VARIABLE] = original_value if original_value
      end

      def test_output_hits_stdout_in_the_absence_of_a_named_pipe
        h = handler
        def h.use_named_pipe?; false; end

        string = 'blackcurrant'

        assert_output(/#{string}/) do
          h.send(:write_output, string)
        end
      end

      def test_output_hits_the_named_pipe_when_available
        temp = Tempfile.new('lambda_named_pipe')
        string = 'rooibos'

        NewRelic::Agent::ServerlessHandler.stub_const(:NAMED_PIPE, temp.path) do
          handler.send(:write_output, string)
        end

        output = File.read(temp).chomp

        assert_equal string, output
      ensure
        temp.close
        temp.unlink
      end

      def test_handle_a_nil_context
        h = handler
        h.send(:parse_context, nil)

        assert_nil h.instance_variable_get(:@function_arn)
        assert_nil h.instance_variable_get(:@function_method)
      end

      def test_handle_a_context_that_does_not_respond_to_arn_and_method_calls
        h = handler
        h.send(:parse_context, :bogus_context)

        assert_nil h.instance_variable_get(:@function_arn)
        assert_nil h.instance_variable_get(:@function_method)
      end

      def test_notice_cold_start_only_does_work_when_cold
        h = handler
        def h.cold?; false; end

        NewRelic::Agent::Tracer.stub :current_transaction, -> { raise 'kaboom' } do
          # because cold is false, the raise won't be reached
          h.send(:notice_cold_start)
        end
      end

      def test_notice_cold_start_only_does_work_with_a_current_transaction_present
        h = handler
        def h.cold?; true; end

        NewRelic::Agent::Tracer.stub :current_transaction, nil do
          h.send(:notice_cold_start)
        end
      end

      def test_write
        temp = Tempfile.new('lambda_named_pipe')
        payload = 'little red bear'
        encoded = NewRelic::Base64.encode64(
          NewRelic::Agent::NewRelicService::Encoders::Compressed::Gzip.encode(payload)
        )
        data = with_output { handler.write(:br_2049, payload) }

        assert_equal 1, data.size
        assert_match(/#{payload}/, data.first)
      end

      def test_write_short_circuits_for_non_serverless_appropriate_methods
        blocked_method = NewRelic::Agent::ServerlessHandler::METHOD_BLOCKLIST.sample

        h = handler
        # guarantee the write doesn't actually take place
        def h.write_output; raise 'kaboom'; end

        assert_nil h.write(blocked_method, 'hoovering')
      end

      private

      def handler
        NewRelic::Agent::ServerlessHandler.new
      end

      def testing_context
        function_arn = 'Resident Alien'
        function_version = '1138'
        context = Minitest::Mock.new
        context.expect :function_arn, function_arn
        context.expect :function_version, function_version
      end

      def with_output(&block)
        temp = Tempfile.new('lambda_named_pipe')
        NewRelic::Agent::ServerlessHandler.stub_const(:NAMED_PIPE, temp.path) do
          yield
        end
        lines = File.read(temp).chomp.split("\n")

        lines.each_with_object([]) do |line, arr|
          next unless line.start_with?('[') && line.end_with?(']')

          parsed = line.split(',').last
          parsed.gsub!(/"|(?:\]\n)|\\n/, '')
          decoded = NewRelic::Base64.decode64(parsed)
          unzipped = Zlib::GzipReader.new(StringIO.new(decoded)).read
          arr.push(unzipped)
        end
      ensure
        temp.close
        temp.unlink
      end
    end
  end
end
