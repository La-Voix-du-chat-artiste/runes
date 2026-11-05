# frozen_string_literal: true

require_relative 'media_adapter'

module Runes
  module LLM
    # Joint audio-video perception through LFM3-Omni-2B. The artifact keeps a
    # singular allowed `modality` (`video` for a soundtracked clip) and lists
    # both senses in `modalities`, so the contract guard can check the family
    # pairing without inventing an `audio_video` modality.
    class OmniAdapter < MediaAdapter
      FAMILY = :omni

      def self.family
        FAMILY
      end
    end
  end
end
