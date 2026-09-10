#!/usr/bin/env ruby
# Standalone embedded broker: `bundle exec ruby demo/broker.rb 1883`.
require_relative '../lib/runes/mqtt/broker'

port = (ARGV[0] || 1883).to_i
Runes::MQTT::Broker.new('127.0.0.1', port).run
