# frozen_string_literal: true

require_relative 'media_adapter'

module Runes
  module LLM
    # Speech, sound-event and audio-description perception through
    # LFM3-Audio-2B.
    class AudioAdapter < MediaAdapter
      FAMILY = :audio

      def self.family
        FAMILY
      end
    end
  end
end
