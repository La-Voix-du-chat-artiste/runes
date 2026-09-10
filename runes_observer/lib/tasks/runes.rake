namespace :runes do
  desc "Subscribe to the Runes MQTT fabric and record every packet (long-running)"
  task ingest: :environment do
    ingest = MqttIngest.new
    %w[INT TERM].each { |sig| Signal.trap(sig) { ingest.stop } }
    ingest.run
  end

  desc "Seed a realistic demo session through the recorder (RUNES_OBSERVER_RESET=0 to append)"
  task demo: :environment do
    DemoFabric.seed!(reset: ENV.fetch("RUNES_OBSERVER_RESET", "1") != "0")
    puts "Seeded #{Packet.count} packet(s) across #{Agent.count} agent(s)."
    puts "  online: #{Agent.online.count}  offline: #{Agent.ended.count}"
  end

  desc "Prune packets older than N days, then cap the table (runes:prune[7])"
  task :prune, [:days] => :environment do |_task, args|
    days = (args[:days] || PacketRecorder.retention_days).to_i
    deleted = PacketRecorder.prune!(days: days)
    puts "Pruned #{deleted} packet(s) older than #{days} day(s); #{Packet.count} remain."
  end

  desc "Delete every observed packet and agent, and the ingest status row"
  task reset: :environment do
    Packet.delete_all
    Agent.delete_all
    IngestStatus.delete_all
    puts "Observer data cleared."
  end

  desc "Print observer statistics"
  task stats: :environment do
    status = IngestStatus.current
    puts "agents : #{Agent.count} (#{Agent.online.count} online, #{Agent.ended.count} offline)"
    puts "packets: #{Packet.count}"
    puts "kinds  : #{Packet.group(:kind).count.sort_by { |_k, v| -v }.to_h}"
    puts "latest : #{Packet.maximum(:occurred_at)}"
    puts "ingest : #{status.display_state} #{status.host}:#{status.port} last=#{status.last_message_at} error=#{status.last_error.inspect}"
  end
end
