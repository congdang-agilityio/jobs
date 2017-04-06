require 'json'
require 'securerandom'
require 'rest-client'

class RideSchedulerWorker
  include Sneakers::Worker

  from_queue ENV['RIDESHARING_RIDE_SCHEDULED_QUEUE'],
    exchange: ENV['RIDESHARING_RIDE_SCHEDULED_EXCHANGE'],
    exchange_options: {
      type: 'x-delayed-message',
      arguments: { 'x-delayed-type': 'direct' },
      durable: true, auto_delete: false },
    queue_options: { durable: true, auto_delete: false },
    routing_key: [''],
    prefetch: 1,
    ack: true,
    timeout_job_after: 90

  def work_with_params(payload, delivery_info, properties)
    params = JSON.parse(payload, symbolize_names: true)

    if params[:status] == 'scheduled'
      params[:status] = 'requested'
      logger.info "Update ride status to #{params[:status]}"

      webhook_push params.slice(:id, :status)
    end

    vendors = user_service_accounts params[:access_token]
    if vendors.empty?
      logger.error "There is no linked service account right now. The scheduled ride can not be processed"
      requeue(params)
      ack!
      return
    end

    logger.info "Start estimating for Scheduled Ride request: #{params} with vendors: #{vendors}"

    scheduled_time = params[:scheduled_time].to_time.utc
    if valid_scheduled_time? scheduled_time
      estimate_request = Ridesharing::EstimateRequest.new ENV['RIDESHARING_ESTIMATE_EXCHANGE'], vendors
      sanitized_estimate_params = estimate_params(params)
      estimate_responses, estimate_errors = estimate_request.call sanitized_estimate_params
      logger.info("Estimated Responses: \n\tRESPONSES: #{estimate_responses}\n\tERRORS: #{estimate_errors}")

      if estimate_responses.present?
        sort_by = params[:sort_by] || 'cheapest'
        car_types = Array(params[:car_types]) | Array(sanitized_estimate_params[:car_types])
        # filtering estimate results
        logger.info "Estimation params #{sort_by}, #{car_types}, #{scheduled_time}"
        estimated = match_estimated_responses estimate_responses, scheduled_time, sort_by, car_types

        # Make a ride request
        if estimated.present?
          make_ride ride_params(params.merge(estimated)), params
        else
          logger.warn "No ride matchs the criterions"
          requeue(params)
        end

      else
        logger.warn "No estimations returned from vendors"
        requeue(params)
      end
    else
      # move this to a method for easy to maintain
      payload = params.slice(:id)
      payload[:status] = 'cancelled'
      payload[:cancelled_by] = 'scheduler'

      webhook_push payload
      logger.warn "Scheduled Ride at #{scheduled_time} was expired"
    end

    ack!
  end

  private

  def estimate_params(params)
    params[:car_types] = [] if params[:car_types].nil? || params[:car_types].size > 1
    params.slice(
      :pickup_latitude,
      :pickup_longitude,
      :destination_latitude,
      :destination_longitude,
      :car_types,
      :passengers)
  end

  def ride_params(params)
    params[:webhook_push] = true
    params.slice(
      :vendor,
      :pickup_latitude,
      :pickup_longitude,
      :pickup_eta,
      :destination_latitude,
      :destination_longitude,
      :car_type,
      :id, # used to replace `ride_request_id` in the future
      :ride_request_id,
      :vehicle_type,
      :payment_method_id,
      :vendor_car_name,
      :car_image_url,
      :price_base,
      :min_time_estimate,
      :min_price_estimate,
      :higher_fare_confirmation,
      :higher_fare_confirmation_token,
      :user_id,
      :status,
      :access_token,
      :webhook_push)
  end

  def valid_scheduled_time?(scheduled_time)
    Time.now.utc + 1.minutes <= scheduled_time
  end

  def sort_by_cheapest(x, y)
    a = x[:min_price_estimate] || x[:price_base]
    b = y[:min_price_estimate] || y[:price_base]
    a && b ? a <=> b : a ? -1 : 1
  end

  def sort_by_fastest(x, y)
    a = x[:pickup_eta]
    b = y[:pickup_eta]
    a && b ? a <=> b : a ? -1 : 1
  end

  def requeue(params)
    scheduled_time = params[:scheduled_time].to_time.utc
    unless valid_scheduled_time?(scheduled_time)
      logger.info "Stop estimating for Scheduled Ride request: #{params[:ride_request_id]}"
      return
    end

    logger.info "Continue estimating for Scheduled Ride request: #{params[:ride_request_id]}"
    delay = 60 * 1_000
    @queue.exchange.publish(params.to_json, {
      content_type: 'application/json',
      headers: { 'x-delay': delay }
    })
  end

  def match_estimated_responses(responses, scheduled_time, sort_by, car_types)
    responses
      .reject {|r| r[:pickup_eta].nil? || r[:pickup_eta] == 0 }
      .select {|r| car_types.empty? || car_types.include?(r[:car_type]) }
      .select {|r|
        time = Time.now.utc + r[:pickup_eta].minutes
        valid = time.between? scheduled_time - 1.minutes, scheduled_time + 15.minutes
        logger.info("ESTIMATION: [#{valid}] pickup_eta: #{time}, scheduled_time: #{scheduled_time}")
        valid
      }
      .sort(&method(:"sort_by_#{sort_by}"))
      .first
  end

  # TODO: remove requeue_params if it is not neccessary
  def make_ride(params, requeue_params = nil)
    ride_request = Ridesharing::RideRequest.new ENV['RIDESHARING_RIDE_EXCHANGE']
    ride_response, ride_error = ride_request.call params
    logger.info("Ride Response: \n\tRESPONSE: #{ride_response}\n\tERROR: #{ride_error}")
    if ride_response.present?
      # TODO: push to webhook

      logger.info("Make a ride has been completed")
    else
      logger.warn "Not able to make a ride"
      if ride_error[:error_code] == 'surge_pricing_confirmation'
        logger.warn "Higher Fare confirmation required"
        token = ride_error.slice(:higher_fare_confirmation_token)

        if params[:higher_fare_confirmation]
          logger.info "Force making a ride with confirmation token #{token[:higher_fare_confirmation_token]}"
          make_ride params.merge(token)
        else
          begin
            response, * = notify_higher_fare_confirmation params
            if response && response[:higher_fare_confirmation]
              logger.info "Higher Fare confirmation: #{response}"
              make_ride params.merge(token)
            end
          rescue ServiceUnavailableError
            logger.warn "There is no confirmation from user"
            requeue(requeue_params)
          end
        end
      else
        logger.info "Retry to make a ride after 1 minute"
        requeue(requeue_params)
      end
    end
  end

  def notify_higher_fare_confirmation(params)
    logger.info "Waiting for Higher Fare confirmation from user ..."

    params[:timeout] = 1.minute.to_i
    params[:expires_at] = Time.now.utc + 1.minute

    confirm = Ridesharing::HigherFareConfirmationRequest.new
    confirm.call(params)
  end

  def webhook_push(params)
    url = "#{ENV['SCHEDULER_API_URL']}/ride/webhooks/#{params[:id]}/status"

    RestClient::Request.execute(
      url: url,
      method: :put,
      headers: { Authorization: "Bearer #{ENV['SCHEDULER_SERVER_TOKEN']}" },
      verify_ssl: false,
      payload: params) rescue nil
  end

  def user_service_accounts(auth_token)
    url = "#{ENV['AUTH_API_URL']}/service_accounts"

    response = RestClient::Request.execute(
      url: url,
      method: :get,
      headers: { Authorization: "Bearer #{auth_token}" },
      verify_ssl: false) rescue nil

    if response
      json = JSON.parse(response.body, symbolize_names: true)
      return json.pluck(:provider)
    end

    []
  end
end
