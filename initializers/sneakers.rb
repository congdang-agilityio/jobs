require 'sneakers'

Sneakers.configure(
  amqp: ENV['RABBITMQ_URL'],
  daemonize: false,
  log: STDOUT)

Sneakers.logger.level = Logger::INFO
