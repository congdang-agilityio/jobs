require 'aws-sdk'
class PushNotificationWorker
  include Sneakers::Worker

  from_queue ENV['PUSH_NOTICATION_QUEUE'],
             exchange_options: { type: 'direct', durable: false, auto_delete: true },
             queue_options: { durable: false },
             prefetch: 1,
             ack: true,
             timeout_job_after: 30,
             exchange: 'sms_send'

  def work_with_params(payload, delivery_info, properties)

    payload = JSON.parse(payload) if properties[:content_type]  == 'application/json'
    endpoint_arn  = payload['endpoint_arn']
    message   = payload['message']

    logger.info("endpoint_arn #{endpoint_arn}")
    logger.info("pushing message #{message}")

    @sns = Aws::SNS::Client.new
    result = @sns.publish(target_arn: endpoint_arn,
              message: message.to_json,
              message_structure: 'json')

    logger.info("Sending result #{result.inspect}")
   ack!
 end
end
