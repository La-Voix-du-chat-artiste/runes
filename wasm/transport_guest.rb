# frozen_string_literal: true

# The in-process transport guest — the FIRST real WASI guest: a
# long-lived, stateful fabric peer, not a one-shot script.
#
# This file is the whole guest: plain Ruby with no third-party requires,
# so the same bytes run under three runtimes:
#
#   * CRuby      — the hermetic test suite spawns it directly
#                  (`ruby wasm/transport_guest.rb <work_dir>`);
#   * ruby.wasm  — the host embeds this source via `ruby -e` with the
#                  work dir mapped to /work (WASI p1 preopen);
#   * Spinel later — the file stays inside the subset; a compiled fleet
#     runtime reuses the same bridge (thread: compiled fleet guest).
#
# The fabric state (subscriptions, retained messages, group round-robin)
# lives HERE, behind the framed file protocol on the mapped directory:
#
#   inbox/%06d.json        one op per file, written by the host (tmp+rename)
#   outbox/%06d_<kind>.json  frames from the guest (tmp+rename)
#
# Ops (all host->guest): subscribe / unsubscribe / publish / stop, each
# carrying "ref" and answered with {"kind":"ack","ref":N} AFTER the op is
# applied — so the host can order subscribe-before-publish across the
# bridge. Boot answers itself with 000000_hello.json. Deliveries:
# {"kind":"delivery","sub":id,"topic":...,"payload":...,"qos":...,
#  "retain":...,"properties":{...}}.
#
# No third-party requires: ruby.wasm ships without the json gem, so the
# guest carries its own minimal JSON-subset codec (FRAME_ENCODE/FRAME_PARSE
# below). The subset is exactly the protocol's vocabulary — strings,
# numbers, booleans, null, nested objects, arrays — which the host's full
# JSON also speaks, so frames stay interoperable both directions. Payloads
# are opaque STRINGS on the wire: the guest never parses a payload.

WORK_DIR = ARGV[0] || "/work"
INBOX = File.join(WORK_DIR, "inbox")
OUTBOX = File.join(WORK_DIR, "outbox")
LOG = File.join(WORK_DIR, "guest.log")
POLL_S = 0.005

# ---- minimal JSON-subset codec (see the header for why) -----------------
module FrameJson
  module_function

  def encode(value)
    case value
    when String then encode_string(value)
    when Integer, Float then value.to_s
    when true, false then value.to_s
    when nil then "null"
    when Array then "[#{value.map { |v| encode(v) }.join(",")}]"
    when Hash
      "{" + value.map { |k, v| "#{encode_string(k.to_s)}:#{encode(v)}" }.join(",") + "}"
    else
      encode_string(value.to_s)
    end
  end

  def encode_string(str)
    "\"#{str.gsub(/[\"\\\\]/, '\\\\\&').gsub(/\n/, "\\n").gsub(/\r/, "\\r").gsub(/\t/, "\\t")}\""
  end

  def parse(text)
    value, pos = parse_value(text, skip_ws(text, 0))
    rest = skip_ws(text, pos)
    raise "trailing bytes at #{rest}" unless rest >= text.length

    value
  end

  def skip_ws(text, pos)
    pos += 1 while pos < text.length && text[pos] =~ /\s/
    pos
  end

  def parse_value(text, pos)
    case text[pos]
    when '"' then parse_string(text, pos)
    when "{" then parse_object(text, pos)
    when "[" then parse_array(text, pos)
    when "t" then [true, pos + 4]
    when "f" then [false, pos + 5]
    when "n" then [nil, pos + 4]
    else
      match = text[pos..].match(/\A-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/)
      raise "bad value at #{pos}" unless match

      num = match[0]
      [num.include?(".") || num.include?("e") || num.include?("E") ? num.to_f : num.to_i,
       pos + num.length]
    end
  end

  def parse_string(text, pos)
    out = +""
    pos += 1
    while pos < text.length
      ch = text[pos]
      if ch == "\\"
        nxt = text[pos + 1]
        case nxt
        when "n" then out << "\n"
        when "r" then out << "\r"
        when "t" then out << "\t"
        when '"' then out << '"'
        when "\\" then out << "\\"
        when "/" then out << "/"
        when "u"
          out << text[pos + 2, 4].to_i(16)
          pos += 4
        else
          raise "bad escape \\#{nxt}"
        end
        pos += 2
      elsif ch == '"'
        return [out, pos + 1]
      else
        out << ch
        pos += 1
      end
    end
    raise "unterminated string"
  end

  def parse_object(text, pos)
    out = {}
    pos += 1
    pos = skip_ws(text, pos)
    return [out, pos + 1] if text[pos] == "}"

    loop do
      key, pos = parse_string(text, pos)
      pos = skip_ws(text, pos)
      raise "expected ':' at #{pos}" unless text[pos] == ":"

      value, pos = parse_value(text, skip_ws(text, pos + 1))
      out[key] = value
      pos = skip_ws(text, pos)
      if text[pos] == ","
        pos = skip_ws(text, pos + 1)
      elsif text[pos] == "}"
        return [out, pos + 1]
      else
        raise "expected ',' or '}' at #{pos}"
      end
    end
  end

  def parse_array(text, pos)
    out = []
    pos += 1
    pos = skip_ws(text, pos)
    return [out, pos + 1] if text[pos] == "]"

    loop do
      value, pos = parse_value(text, skip_ws(text, pos))
      out << value
      pos = skip_ws(text, pos)
      if text[pos] == ","
        pos = skip_ws(text, pos + 1)
      elsif text[pos] == "]"
        return [out, pos + 1]
      else
        raise "expected ',' or ']' at #{pos}"
      end
    end
  end
end

# WASI note: append-mode opens and path-existence lookups are the least
# uniformly implemented bits of WASI p1 across runtimes, so the log is a
# whole-file rewrite from an in-memory buffer and mkdir is try/rescue.
LOG_LINES = []

def log(line)
  LOG_LINES << "#{line}\n"
  File.write(LOG, LOG_LINES.join)
end

# Topic matching for the in-guest hub: `+` one level, `#` tail. Mirrors
# Runes::Transport::TopicFilter.match? semantics — the adapter's contract
# tests pin both sides to the same observable behavior.
def topic_match?(filter, topic)
  f = filter.split("/")
  t = topic.split("/")
  i = 0
  while i < f.length
    return true if f[i] == "#"
    return false if i >= t.length
    return false if f[i] != "+" && f[i] != t[i]

    i += 1
  end
  i == t.length
end

class GuestHub
  def initialize
    @subscriptions = [] # {id, filter, group}
    @retained = {}      # topic => {payload, qos, properties}
    @group_cursor = Hash.new(0)
    @seq = 0
  end

  def subscribe(id, filter, group)
    @subscriptions.reject! { |s| s[:id] == id }
    @subscriptions << { id: id, filter: filter, group: group }
    return unless group.nil?

    # Retained replay for plain subs only (same rule as InProcess: a
    # shared group's members split live work; replaying retained to each
    # member would duplicate state seeding).
    @retained.each do |topic, r|
      next unless topic_match?(filter, topic)

      yield delivery_frame(id, topic, r[:payload], r[:qos], true, r[:properties])
    end
  end

  def unsubscribe(id)
    @subscriptions.reject! { |s| s[:id] == id }
  end

  def publish(topic, payload, qos, retain, properties)
    if retain
      payload.to_s.empty? ? @retained.delete(topic) : @retained[topic] = { payload: payload, qos: qos, properties: properties }
    end

    matched = @subscriptions.select { |s| topic_match?(s[:filter], topic) }
    plain = matched.select { |s| s[:group].nil? }
    shared = matched.reject { |s| s[:group].nil? }
                 .group_by { |s| s[:group] }
                 .map do |group, members|
                   member = members[@group_cursor[group] % members.size]
                   @group_cursor[group] += 1
                   member
                 end
    (plain + shared).each do |sub|
      yield delivery_frame(sub[:id], topic, payload, qos, false, properties)
    end
  end

  def ack_frame(ref)
    @seq += 1
    { kind: "ack", ref: ref, seq: @seq }
  end

  private

  def delivery_frame(sub, topic, payload, qos, retain, properties)
    @seq += 1
    { kind: "delivery", sub: sub, topic: topic, payload: payload,
      qos: qos, retain: retain, properties: properties || {}, seq: @seq }
  end
end

def write_frame(frame)
  seq = frame.delete(:seq)
  tmp = File.join(OUTBOX, "tmp_#{seq}_#{frame[:kind]}.json")
  final = File.join(OUTBOX, format("%06d_%s.json", seq, frame[:kind]))
  File.write(tmp, FrameJson.encode(frame))
  File.rename(tmp, final)
end

def boot_hello
  tmp = File.join(OUTBOX, "tmp_hello.json")
  File.write(tmp, FrameJson.encode({ "kind" => "hello" }))
  File.rename(tmp, File.join(OUTBOX, "000000_hello.json"))
end

def main
  begin
    Dir.mkdir(INBOX)
  rescue Errno::EEXIST
    nil
  end
  begin
    Dir.mkdir(OUTBOX)
  rescue Errno::EEXIST
    nil
  end
  pid = (Process.pid rescue 0) # WASI has no processes
  log "guest boot pid=#{pid} work=#{WORK_DIR}"
  hub = GuestHub.new
  boot_hello

  loop do
    stop = false
    Dir[File.join(INBOX, "*.json")].sort.each do |path|
      # tmp_* files are the host's write-in-progress; rename makes a frame
      # visible atomically, so a glob hit on tmp_* means "not yet".
      next if File.basename(path).start_with?("tmp_")

      op = begin
        FrameJson.parse(File.read(path))
      rescue StandardError => e
        log "dropping unparseable op #{File.basename(path)}: #{e.message}"
        File.delete(path)
        next
      end
      File.delete(path)
      case op["op"]
      when "subscribe"
        hub.subscribe(op["id"], op["filter"], op["group"]) do |frame|
          write_frame(frame)
        end
      when "unsubscribe"
        hub.unsubscribe(op["id"])
      when "publish"
        hub.publish(op["topic"], op["payload"], op["qos"] || 0, op["retain"] || false, op["properties"]) do |frame|
          write_frame(frame)
        end
      when "stop"
        stop = true
      else
        log "unknown op: #{op.inspect}"
      end
      write_frame(hub.ack_frame(op["ref"])) if op["ref"]
    end
    break if stop

    sleep POLL_S
  end
  log "guest stopped"
end

begin
  main
rescue => e
  log "guest FATAL #{e.class}: #{e.message}"
  raise
end
