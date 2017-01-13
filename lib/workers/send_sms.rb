#!/usr/bin/env ruby
# encoding: utf-8

require 'sneakers'
require 'twilio-ruby'
require 'byebug'

class SendSmsWorker
  include Sneakers::Worker

  from_queue ENV['SMS_QUEUE'],
             exchange_options: { type: 'direct', durable: false, auto_delete: true },
             queue_options: { durable: false },
             prefetch: 1,
             ack: true,
             timeout_job_after: 30,
             exchange: 'sms_send'

  def work_with_params(payload, delivery_info, properties)

    payload = JSON.parse(payload) if properties[:content_type]  == 'application/json'
    phone_number  = payload['to']
    message   = payload['message']

    logger.info("receive number #{phone_number}")
    logger.info("sending message #{message}")

    # set up a client to talk to the Twilio REST API
    @client = Twilio::REST::Client.new
    @client.messages.create(
      from: ENV['TWILIO_SMS_SENDER'],
      to: phone_number,
      body: message
    )
   ack!
 end
end
