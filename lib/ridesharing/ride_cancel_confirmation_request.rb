module Ridesharing
  class RideCancelConfirmationRequest
    def initialize
      @conn = Bunny.new
      @conn.start
      @channel = @conn.create_channel
    end

    def call(params)
      name = "ride-cancel-confirmation-response-#{params[:id]}"

      *, payload = @channel.basic_get name, manual_ack: false rescue nil

      @channel.close unless @channel.closed?
      @conn.close unless @conn.closed?

      payload.present?
    end
  end
end

