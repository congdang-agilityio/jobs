require 'bunny-rpc'
module Ridesharing
  class RideRequest < BunnyRpc
    private

    def request_id
      @request_id ||= @channel.generate_consumer_tag('scheduled-ride-request')
    end
  end
end
