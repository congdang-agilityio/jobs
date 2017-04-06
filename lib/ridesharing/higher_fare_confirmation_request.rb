require 'rest-client'

module Ridesharing
  class HigherFareConfirmationRequest < BunnyRpc
    def initialize
      @conn = Bunny.new
      @conn.start
      @channel = @conn.create_channel
      @response = {}
      @error = {}
    end

    def call(params)
      # FIXME
      @id = params[:id]
      @response_queue = @channel.queue(request_id, exclusive: true, durable: false, auto_delete: true)

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
      metadata = {
        service_type: 'ridesharing',
        event_type: 'higher_fare_confirmation',
        status: params[:status],
        id: params[:id],
        expires_at: params.delete(:expires_at)
      }
      message = params[:vendor] == 'uber' && 'We found you a ride, but surge pricing is in effect. Tap to confirm.' ||
        'We found you a ride, but Prime Time pricing is in effect. Tap to confirm.'

      payload = {
        user_id: params[:user_id],
        message: message,
        metadata: metadata
      }

      send_push_notification payload
    end

    def request_id
      # TODO: user ENV for this queue name
      @request_id ||= "higher-fare-confirmation-request-#{@id}"
    end

    # MOVE OUT OF THIS SCOPE
    def send_push_notification(params)
      url = "#{ENV['AUTH_API_URL']}/notifications"
      server_token = ENV['AUTH_SERVER_TOKEN']

      RestClient::Request.execute(
        url: url,
        method: :post,
        headers: { Authorization: "Bearer #{server_token}", "Content-Type": "application/json"},
        verify_ssl: false,
        payload: params.to_json) rescue nil
    end
  end
end
