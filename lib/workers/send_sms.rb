#!/usr/bin/env ruby
# encoding: utf-8

require 'sneakers'

class Workers::SendSmsWorker
  include Sneakers::Worker

  from_queue 'tize.sms',
             exchange_options: { type: 'direct', durable: false, auto_delete: true },
             queue_options: { durable: false },
             routing_key: [''],
             ack: true,
             # :threads: 10,
             prefetch: 1,
             timeout_job_after: 1,
             exchange: 'search_request'
             # :heartbeat: 1
             # :amqp_heartbeat: 1

  # def work(msg)
  #   puts msg
  #   publish "cleaned up", :to_queue => "foobar"
  #   ack!
  # end

  def work_with_params(delivery_info, properties, payload)
    puts delivery_info, properties, payload
    ack!
  end

end
