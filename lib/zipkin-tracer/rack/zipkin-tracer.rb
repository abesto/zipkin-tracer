# Copyright 2012 Twitter Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require 'finagle-thrift'
require 'finagle-thrift/trace'
require 'sucker_punch'
require 'zipkin-tracer/config'

module ZipkinTracer

  class RackHandler
    B3_REQUIRED_HEADERS = %w[HTTP_X_B3_TRACEID HTTP_X_B3_PARENTSPANID HTTP_X_B3_SPANID HTTP_X_B3_SAMPLED]
    B3_OPT_HEADERS = %w[HTTP_X_B3_FLAGS]

    def initialize(app, config = nil)
      @app = app
      @lock = Mutex.new

      config = Config.new(app, config)
      SuckerPunch.logger = config.logger
      adapter = config.adapter

      ::Trace.tracer = case adapter
        when :json
          require 'zipkin-tracer/zipkin_json_tracer'
          ::Trace::ZipkinJsonTracer.new(json_api_host: config.json_api_host, traces_buffer: config.traces_buffer)
        when :scribe
          require 'zipkin-tracer/careless_scribe'
          ::Trace::ZipkinTracer.new(CarelessScribe.new(config.scribe_server), config.scribe_max_buffer)
        when :kafka
          require 'zipkin-tracer/zipkin_kafka_tracer'
          ::Trace::ZipkinKafkaTracer.new(zookeepers: config.zookeeper)
        else
          ::Trace::NullTracer.new
      end

      ip_format = config.adapter == :json ? :string : :i32
      ::Trace.default_endpoint = ::Trace::Endpoint.make_endpoint(
        nil, # auto detect hostname
        config.service_port,
        service_name(config.service_name),
        ip_format
      )
      ::Trace.sample_rate = config.sample_rate

      @config = config
    end

    def call(env)
      # skip certain requests
      return @app.call(env) if filtered?(env) || !routable_request?(env)

      whitelisted = force_sample?(env)
      id = get_or_create_trace_id(env, whitelisted) # note that this depends on the sample rate being set
      tracing_filter(id, env, whitelisted) { @app.call(env) }
    end

    private

    def record(annotation)
      ::Trace.record(annotation)
    # Nothing wonky that the tracer does should stop us from using the app!!!
    # Usually is better to rescue StandardError but the socket layer can launch Errno kind of exceptions
    rescue Exception
      # Ignore low level errors
    end

    # Use the Domain environment variable to extract the service name, otherwise use the default config name
    def service_name(default_name)
      ENV["DOMAIN"].to_s.empty? ? default_name : ENV["DOMAIN"].split('.').first
    end

    # If the request is not valid for this service, we do not what to trace it.
    def routable_request?(env)
      return true unless defined?(Rails) # If not running on a Rails app, we can't verify if it is invalid
      Rails.application.routes.recognize_path(env['PATH_INFO'])
      true
    rescue ActionController::RoutingError
      false
    end

    def annotate(env, status, response_headers, response_body)
      @config.annotate_plugin.call(env, status, response_headers, response_body) if @config.annotate_plugin
    end

    def filtered?(env)
      @config.filter_plugin && !@config.filter_plugin.call(env)
    end

    def force_sample?(env)
      @config.whitelist_plugin && @config.whitelist_plugin.call(env)
    end

    def tracing_filter(trace_id, env, whitelisted)
      synchronize do
        ::Trace.push(trace_id)
        #if called by a service, the caller already added the information
        add_request_information(env) unless called_with_zipkin_headers?(env)
        record(::Trace::Annotation.new(::Trace::Annotation::SERVER_RECV, ::Trace.default_endpoint))
        record(::Trace::Annotation.new('whitelisted', ::Trace.default_endpoint)) if whitelisted
      end
      status, headers, body = yield
    ensure
      synchronize do
        annotate(env, status, headers, body)
        record(::Trace::Annotation.new(::Trace::Annotation::SERVER_SEND, ::Trace.default_endpoint))
        ::Trace.pop
      end
      [status, headers, body]
    end

    def add_request_information(env)
      ::Trace.set_rpc_name(env['REQUEST_METHOD'].to_s.downcase) # get/post and all that jazz
      record(::Trace::BinaryAnnotation.new('http.uri', env['PATH_INFO'], 'STRING', ::Trace.default_endpoint))
    end

    def called_with_zipkin_headers?(env)
      B3_REQUIRED_HEADERS.all? { |key| env.has_key?(key) }
    end

    def synchronize(&block)
      @lock.synchronize do
        yield
      end
    rescue => e
      @config.logger.error("Exception #{e.message} while sending Zipkin traces. #{e.backtrace}")
    end

    def get_or_create_trace_id(env, whitelisted, default_flags = ::Trace::Flags::EMPTY)
      trace_parameters = if called_with_zipkin_headers?(env)
                           env.values_at(*B3_REQUIRED_HEADERS)
                         else
                           new_id = Trace.generate_id
                           [new_id, nil, new_id, ('true' if whitelisted || Trace.should_sample?)]
                         end
      trace_parameters[3] = (trace_parameters[3] == 'true')

      trace_parameters += env.values_at(*B3_OPT_HEADERS) # always check flags
      trace_parameters[4] = (trace_parameters[4] || default_flags).to_i

      Trace::TraceId.new(*trace_parameters)
    end
  end
end
