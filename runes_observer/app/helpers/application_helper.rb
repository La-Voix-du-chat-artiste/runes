module ApplicationHelper
  # NOTE: ingest_status lives on ApplicationController (helper_method) so
  # both controllers and views share one memoized implementation.

  def state_pill(state, label = nil)
    tag.span(label || state, class: "pill pill--#{state}")
  end

  def kind_badge(kind)
    tag.span(kind, class: "badge badge--#{kind.to_s.tr('_', '-')}")
  end

  # A signature badge, or nothing at all when the packet is unsigned: most
  # fabric traffic is, and a badge on every row would be noise rather than
  # information. Unsigned packets are still labelled on the packet page and in
  # the security panel.
  def signature_badge(packet, short: true)
    return nil unless packet.signed?

    label = short ? packet.signature_state : "#{packet.signature_state} #{packet.fingerprint_label}"
    tag.span(label, class: "badge badge--sig-#{packet.signature_state}",
                   title: packet.signature_tooltip)
  end

  def nav_link(label, path)
    active = current_page?(path)
    link_to label, path, class: "nav__link#{' nav__link--active' if active}"
  end

  # "3s" / "4m" / "2h" / "5d"
  def ago_in_words_short(time)
    return "—" if time.blank?

    seconds = (Time.current - time).round
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  def clock_time(time)
    return "—" if time.blank?

    time.strftime("%H:%M:%S")
  end

  def byte_size_label(bytes)
    bytes = bytes.to_i
    return "#{bytes} B" if bytes < 1024
    return "#{(bytes / 1024.0).round(1)} KiB" if bytes < 1024 * 1024

    "#{(bytes / (1024.0 * 1024)).round(1)} MiB"
  end

  def json_pretty(text)
    parsed = JSON.parse(text.to_s)
    JSON.pretty_generate(parsed)
  rescue JSON::ParserError
    text.to_s
  end

  # Truncates an agent id for narrow columns without losing the full value.
  def short_id(id, limit = 28)
    value = id.to_s
    return value if value.length <= limit

    "#{value[0, limit - 1]}…"
  end
end
