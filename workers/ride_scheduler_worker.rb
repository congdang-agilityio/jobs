require 'json'

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
    timeout_job_after: 30

  def work_with_params(payload, delivery_info, properties)
    params = JSON.parse(payload, symbolize_names: true)
    logger.info "Start estimating for Scheduled Ride request: #{params}"

    scheduled_time = params[:scheduled_time].to_time.utc
    if valid_scheduled_time? scheduled_time
      estimate_request = Ridesharing::EstimateRequest.new ENV['RIDESHARING_ESTIMATE_EXCHANGE']
      sanitized_estimate_params = estimate_params(params)
      estimate_responses, estimate_errors = estimate_request.call sanitized_estimate_params
      logger.info("Estimated Responses: \n\tRESPONSES: #{estimate_responses}\n\tERRORS: #{estimate_errors}")

      if estimate_responses.present?
        sort_by = params[:sort_by] || 'cheapest'
        car_types = Array(params[:car_types]) | Array(sanitized_estimate_params[:car_types])
        # filtering estimate results
        estimated = match_estimated_responses estimate_responses, scheduled_time, sort_by, car_types

        # Make a ride request
        if estimated.present?
          ride_request = Ridesharing::RideRequest.new ENV['RIDESHARING_RIDE_EXCHANGE']
          ride_response, ride_error = ride_request.call ride_params(params.merge(estimated))
          logger.info("Ride Response: \n\tRESPONSE: #{ride_response}\n\tERROR: #{ride_error}")
          if ride_response.present?
            # TODO: push to webhook

            logger.info("Make a ride has been completed")
          else
            logger.warn "Not able to make a ride"
            requeue(params)
          end
        else
          logger.warn "No ride matchs the criterions"
          requeue(params)
        end

      else
        logger.warn "No estimations returned from vendors"
        requeue(params)
      end
    else
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
      :ride_request_id,
      :vendor_car_name,
      :car_image_url,
      :price_base,
      :min_time_estimate,
      :min_price_estimate,
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
        valid = time.between? scheduled_time, scheduled_time + 15.minutes
        logger.info("ESTIMATION: [#{valid}] pickup_eta: #{time}, scheduled_time: #{scheduled_time}")
        valid
      }
      .sort(&method(:"sort_by_#{sort_by}"))
      .first
  end
end
