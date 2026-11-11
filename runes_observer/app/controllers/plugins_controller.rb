# O1.6 — the plugin/rune catalog, generated from the registry so it cannot
# go stale: the same trick as the shipped example file being the one the
# tests read. "A rune is a plugin" as a page.
class PluginsController < ApplicationController
  def index
    @plugins = plugin_definitions
    @harness_available = !@plugins.nil?
  end

  private

  def plugin_definitions
    require "runes/workflow" # registers the seven runes
    Runes::Plugin.all(kind: :rune).map do |definition|
      {
        name: definition.name.to_s,
        kind: definition.kind.to_s,
        description: definition.description.to_s,
        klass: definition.klass.to_s,
        source: definition.klass.instance_method(:execute).source_location&.first.to_s
      }
    end.sort_by { |p| p[:name] }
  rescue LoadError, StandardError => e
    Rails.logger.warn("[observer] plugin registry unavailable: #{e.class}: #{e.message}")
    nil
  end
end
