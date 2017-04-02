require 'concurrent'

module Ridesharing
  class EstimateRequest
    attr_accessor :responses
    attr_accessor :errors
    attr_reader :response_queue

    attr_reader :latch

    def initialize(exchange_name)
      @conn = Bunny.new
      @conn.start
      @channel = @conn.create_channel
      @exchange = @channel.direct(exchange_name, durable: false, auto_delete: true)
      @response_queue = @channel.queue("", exclusive: true, durable: false, auto_delete: true)
      @responses = []
      @errors = []

      # TODO: get from rabbitmq
      provider_count = 1
      # enable countdownlatch
      @latch = Concurrent::CountDownLatch.new(provider_count)
      Thread.new do
        @response_queue.subscribe do |delivery_info, properties, payload|
          if properties[:correlation_id] == request_id
            response = JSON.parse(payload, symbolize_names: true)
            if properties[:type] == 'error'
              @errors << response
            else
              @responses += response
            end

            @latch.count_down
          end
        end
      end
    end

    def call(params)
      @exchange.publish(params.to_json,
        correlation_id: request_id,
        reply_to: @response_queue.name,
        content_type: 'application/json'
      )

      @latch.wait 15

      @channel.close
      @conn.close
      [@responses, @errors]
    end

    private

    def request_id
      @request_id ||= @channel.generate_consumer_tag('estimates-request')
    end
  end
end
