# frozen_string_literal: true

module Runes
  module Security
    # Broker username/password/JWT material, read from the environment.
    #
    #   Runes::Security::Credentials.for_transport(settings)
    #   # => { username: 'runes-a', password: '…' }   # when both are set
    #   # => {}                                        # when neither is set
    #
    #   Runes::Security::Credentials.token(settings)
    #   # => 'eyJ…' or nil                           # RUNES_MQTT_TOKEN
    #
    # Values come from the Settings env lookup when a Settings-like object
    # is passed (real ENV wins over config/.env), otherwise from ENV.
    # Credential material is never interpolated into logs or errors:
    # #inspect and #to_s redact every value.
    class Credentials
      ENV_USERNAME = 'RUNES_MQTT_USERNAME'
      ENV_PASSWORD = 'RUNES_MQTT_PASSWORD'
      ENV_TOKEN    = 'RUNES_MQTT_TOKEN'
      REDACTED     = '[REDACTED]'

      class << self
        # Connection options for the broker transport. An empty hash means
        # "anonymous" — callers must not treat that as an error.
        def for_transport(settings = nil)
          username = value(ENV_USERNAME, settings)
          password = value(ENV_PASSWORD, settings)
          return {} if username.nil? && password.nil?

          { username: username.to_s, password: password.to_s }
        end

        # JWT / bearer token for brokers that use token auth.
        def token(settings = nil)
          value(ENV_TOKEN, settings)&.to_s
        end

        def username(settings = nil)
          value(ENV_USERNAME, settings)&.to_s
        end

        def password(settings = nil)
          value(ENV_PASSWORD, settings)&.to_s
        end

        # Snapshot the environment into a redactable value object.
        def from_env(settings = nil)
          new(username: username(settings), password: password(settings), token: token(settings))
        end
        alias load from_env

        private

        # Empty strings count as unset (an exported-but-blank .env var must
        # not produce `username: ''`).
        def value(key, settings)
          raw = if settings.respond_to?(:env)
                  settings.env(key)
                else
                  ENV[key]
                end
          text = raw.to_s
          text.strip.empty? ? nil : text
        end
      end

      attr_reader :username, :password, :token

      def initialize(username: nil, password: nil, token: nil)
        @username = blank_to_nil(username)
        @password = blank_to_nil(password)
        @token = blank_to_nil(token)
      end

      def configured?
        !(username.nil? && password.nil? && token.nil?)
      end

      def empty?
        !configured?
      end

      # Transport options, omitting unset fields.
      def to_transport
        out = {}
        out[:username] = username if username
        out[:password] = password if password
        out
      end

      # Redacted on purpose: this object may be in a hash a logger prints.
      def inspect
        "#<Runes::Security::Credentials username=#{mask(username)} " \
          "password=#{mask(password)} token=#{mask(token)} configured=#{configured?}>"
      end

      def to_s
        inspect
      end

      private

      def blank_to_nil(value)
        text = value.to_s
        text.strip.empty? ? nil : text
      end

      def mask(value)
        value.nil? ? 'nil' : REDACTED
      end
    end
  end
end
