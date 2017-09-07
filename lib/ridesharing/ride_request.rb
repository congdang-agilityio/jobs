require 'concurrent'
module Ridesharing

  class ServiceUnavailableError < StandardError; end

  class RideRequest
    attr_reader :latch

    def initialize(exchange_name)
      @conn = Bunny.new
      @conn.start
      @channel = @conn.create_channel
      @exchange = @channel.direct(exchange_name, durable: false, auto_delete: true)
      @response_queue = @channel.queue("", exclusive: true, durable: false, auto_delete: true)
      @response = {}
      @error = {}
    end

    def call(params)
      provider_count = 1
      # enable countdownlatch
      @latch = Concurrent::CountDownLatch.new(provider_count)

      subscribe
      publish params

      timeout = params.delete :timeout || 30
      success = @latch.wait timeout

      @channel.close
      @conn.close

      unless success
        raise ServiceUnavailableError
      end

      [@response, @error]
    end

    private

    def publish(params)
      @exchange.publish(params.to_json,
        correlation_id: request_id,
        reply_to: @response_queue.name,
        content_type: 'application/json',
        routing_key: params[:vendor]
      )
    end

    def subscribe
      Thread.new do
        @response_queue.subscribe do |delivery_info, properties, payload|
          if properties[:correlation_id] == request_id
            response = JSON.parse(payload, symbolize_names: true)
            if properties[:type] == 'error'
              @error = response
            else
              @response = response
            end

            @latch.count_down
          end
        end
      end
    end

    def request_id
      @request_id ||= @channel.generate_consumer_tag('scheduled-ride-request')
    end
  end

end

