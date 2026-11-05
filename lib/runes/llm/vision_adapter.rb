# frozen_string_literal: true

require_relative 'media_adapter'

module Runes
  module LLM
    # Image/video/document/chart/screen perception through LFM3-VL-2B.
    class VisionAdapter < MediaAdapter
      FAMILY = :vision

      def self.family
        FAMILY
      end
    end
  end
end
