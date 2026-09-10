# frozen_string_literal: true

# TUI hardening regression tests (T4-1 … T4-10).
#
# Loads bin/runes directly (like test/mode_commands_test.rb and
# test/verifier_followup_test.rb already do). bin/runes only starts the
# TUI when `File.expand_path(__FILE__) == File.expand_path($0)`, so under
# minitest it is pure class definitions.
#
# These tests never touch the network or an API key: every TUI instance
# is built with an unreachable port and `publish_envelope` is stubbed
# wherever a command path is exercised. Terminal I/O is driven through
# StringIO stand-ins so no real tty is required.
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'
# Pull in the shared hermetic test bootstrap (temp RUNES_ROOT + provider
# keys stripped) even when this file is run on its own (B4-13).
require_relative 'test_helper'

load File.expand_path('../bin/runes', __dir__) unless defined?(RunesTUI)

class TuiHardeningTest < Minitest::Test
  # A StringIO-like stdin for raw-mode readers: deterministic getch and
  # an IO.select stub (IO.select cannot operate on StringIO).
  class FakeInput
    def initialize(data)
      @io = StringIO.new(data.to_s.dup.force_encoding('BINARY'))
    end

    def getch
      c = @io.getc
      c.nil? ? nil : c.force_encoding('BINARY')
    end

    def remaining
      @io.read.to_s
    end

    def selectable?
      !@io.eof?
    end
  end

  def setup
    @root = Dir.mktmpdir('tui-hardening')
    @tui = RunesTUI.new(host: '127.0.0.1', port: 5999, root: @root)
  end

  def teardown
    # SAFETY: only ever remove a tmpdir root — a default (project) root
    # here deleted the whole repository once.
    FileUtils.remove_entry(@root) if @root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(@root)
  end

  # --- T4-1: non-object JSON must not raise --------------------------------

  def test_non_object_card_payload_does_not_raise
    ['[]', 'null', '5', '"just a string"', 'true', '{}'].each do |body|
      @tui.handle_event('runes/agents/ghost/card', body)
    end
    # Every non-object body degraded to an empty card (no tools) instead
    # of raising TypeError out of handle_event.
    assert_equal '', @tui.instance_variable_get(:@agents)['ghost']['tools']
    assert(@tui.instance_variable_get(:@traffic).any? { |l| l.include?('[card] ghost') })
  end

  def test_non_object_progress_payload_does_not_raise
    ['[]', 'null', '5', '"x"', 'false'].each do |body|
      @tui.handle_event('runes/prompts/req-1/progress', body)
    end
    traffic = @tui.instance_variable_get(:@traffic)
    assert_equal 5, traffic.size
    # The fallback row carries the (scrubbed, bounded) raw body.
    assert(traffic.any? { |l| l.include?('[]') })
  end

  def test_valid_object_payloads_still_work
    @tui.handle_event('runes/agents/ok/card', JSON.generate('tools' => %w[echo read]))
    assert_equal 'echo, read', @tui.instance_variable_get(:@agents)['ok']['tools']

    @tui.handle_event('runes/prompts/r9/progress', JSON.generate('event' => 'conversation', 'text' => 'hi'))
    assert(@tui.instance_variable_get(:@traffic).any? { |l| l.include?('agent: hi') })
  end

  # --- T4-2: invalid UTF-8 in the topic must not raise ---------------------

  def test_invalid_utf8_topic_does_not_raise
    bad_card = "runes/agents/\xff\xfe/card".b
    bad_progress = "runes/prompts/\xc3/progress".b
    @tui.handle_event(bad_card, '{"tools":["echo"]}')
    @tui.handle_event(bad_progress, '{event is not json')
    # Nothing escaped: the reader thread would have died on this.
    assert_kind_of Hash, @tui.instance_variable_get(:@agents)
    assert_operator @tui.instance_variable_get(:@traffic).size, :>=, 1
  end

  def test_invalid_utf8_status_topic_matches_after_scrub
    @tui.handle_event("runes/agents/bad\xffid/status".b, 'online')
    ids = @tui.instance_variable_get(:@agents).keys
    assert(ids.any? { |id| id.start_with?('bad') && id.end_with?('id') },
           "scrubbed id should still route to the status branch, got #{ids.inspect}")
  end

  def test_invalid_utf8_payload_does_not_raise
    # BINARY payload bytes used to raise Encoding::CompatibilityError when
    # the control-char regexp was matched against them.
    @tui.handle_event('runes/agents/enc/status', "onl\xffine\xfe".b)
    @tui.handle_event('runes/prompts/response', "\xc3(\x92raw".b)
    line = @tui.instance_variable_get(:@traffic).last
    refute_match(/[\x00-\x1f\x7f]/, line)
    assert_equal "response: \uFFFD(\uFFFDraw", line
  end

  # --- T4-5: newlines/tabs in payloads must not forge traffic rows ---------

  def test_status_payload_cannot_paint_a_forged_row
    @tui.handle_event('runes/agents/x/status', "online\nforged row\e[2;1H\tpwn")
    line = @tui.instance_variable_get(:@traffic).last
    refute_match(/[\x00-\x1f\x7f]/, line, 'control characters reached the traffic row')
    assert_equal 1, line.lines.size, 'a payload newline painted an extra traffic row'
    # Control bytes became separators; the payload text stayed on the row.
    assert_equal '[online forged row[2;1H pwn] x', line
  end

  def test_newline_payload_still_shows_collapsed_text
    @tui.handle_event('runes/prompts/response', "line one\nline two")
    line = @tui.instance_variable_get(:@traffic).last
    refute_match(/[\x00-\x1f\x7f]/, line)
    assert_includes line, 'line one line two'
  end

  def test_sanitize_strips_control_bytes_from_osc_payloads
    # The bytes the terminal interprets (ESC, BEL, LF, TAB) are gone even
    # though the printable remainder of the OSC body survives.
    assert_equal 'a b', RunesTUI.sanitize("a\tb\n")
    scrubbed = RunesTUI.sanitize("\x1b]52;c;payload\x07")
    refute_match(/[\x00-\x1f\x7f]/, scrubbed)
    refute_includes scrubbed, "\e"
    assert_equal ']52;c;payload', scrubbed
  end

  # --- T4-4: traffic_notice respects the cap -------------------------------

  def test_traffic_notice_respects_the_cap
    cap = @tui.instance_variable_get(:@traffic_limit)
    5.times { @tui.traffic_notice('pad') }
    (cap * 2 + 25).times { |i| @tui.traffic_notice("notice-#{i}") }

    traffic = @tui.instance_variable_get(:@traffic)
    assert_operator traffic.size, :<=, cap
    assert_equal "» notice-#{cap * 2 + 24}", traffic.last
    # The oldest notices were shifted out; the newest survived.
    refute(traffic.any? { |l| l == '» pad' })
  end

  def test_submit_buffer_respects_the_cap
    cap = @tui.instance_variable_get(:@traffic_limit)
    @tui.define_singleton_method(:handle_line) { |_l| nil }
    (cap + 20).times do |i|
      @tui.instance_variable_set(:@input, "prompt #{i}")
      @tui.instance_variable_set(:@cursor, @tui.instance_variable_get(:@input).length)
      @tui.submit_buffer
    end
    assert_operator @tui.instance_variable_get(:@traffic).size, :<=, cap
  end

  # --- T4-6: pasted/piped/typed input is scrubbed --------------------------

  def test_scrub_input_keeps_printables_and_newlines_but_drops_escapes
    assert_equal "hi\nthere", RunesTUI.scrub_input("hi\nthere")
    assert_equal 'ab  c', RunesTUI.scrub_input("ab\tc")
    # The ESC and BEL are stripped; the printable OSC body is inert text.
    assert_equal ']52;c;cGF5bG9hZAsafe', RunesTUI.scrub_input("\e]52;c;cGF5bG9hZA\asafe")
    refute_match(/[\x00-\x08\x0b-\x1f\x7f]/, RunesTUI.scrub_input("\e]52;c;cGF5bG9hZA\asafe"))
    assert_equal 'ok', RunesTUI.scrub_input("o\x7fk")
    refute_match(/[\x00-\x08\x0b-\x1f\x7f]/, RunesTUI.scrub_input("\x1b[2Jx\r\ny"))
  end

  def test_typed_escape_bytes_never_reach_the_input_buffer
    @tui.apply_key("\e]52;c;cGF5bG9hZA\a")
    input = @tui.instance_variable_get(:@input)
    refute_match(/[\x00-\x08\x0b-\x1f\x7f]/, input)
    refute_includes input, "\e"
    @tui.apply_key('ok')
    assert_equal ']52;c;cGF5bG9hZAok', @tui.instance_variable_get(:@input)
  end

  def test_pasted_escape_bytes_never_reach_the_input_buffer
    paste = "safe\e]52;c;payload\a text"
    @tui.apply_key(paste)
    assert_equal 'safe]52;c;payload text', @tui.instance_variable_get(:@input)

    # The rendered frame must not contain the OSC bytes either.
    frame = @tui.compose_frame({}, [], :build, nil, @tui.instance_variable_get(:@input), 0)
    refute_includes frame, "\e]52"
  end

  def test_paste_body_scrub_keeps_newlines_and_drops_escapes
    body = "one\r\ntwo\rthree"
    text = @tui.read_paste_text(body)
    assert_equal "one\ntwo\nthree", text
    refute_match(/[\x00-\x08\x0b-\x1f\x7f]/, text)
    # A terminator that is present is removed, not inserted.
    assert_equal 'x', @tui.read_paste_text("x#{RunesTUI::PASTE_END}")
  end

  # --- T4-7: an over-cap paste is drained, not re-read as keystrokes -------

  def test_oversized_paste_is_drained_to_the_terminator
    cap = RunesTUI::LIMITS[:paste_bytes]
    # 64 KiB+ body, then the leftover bytes a real terminal would still
    # have queued: the tail plus the bracket terminator. The old reader
    # abandoned the paste here and re-read the tail as keys — the CR
    # would have auto-submitted a partial prompt.
    data = ('a' * (cap + 40)) + "tail\r" + RunesTUI::PASTE_END
    fake = FakeInput.new(data)
    notices = []
    @tui.define_singleton_method(:traffic_notice) { |m| notices << m }
    with_stdin(fake) { @tui.read_paste }

    assert(fake.remaining.empty?, 'the remainder must be drained, not left for read_key')
    assert(notices.any? { |m| m.include?('paste truncated') }, 'truncation must be announced')
  end

  def test_paste_missing_terminator_is_bounded_and_reported
    fake = FakeInput.new('x' * 32)
    notices = []
    @tui.define_singleton_method(:traffic_notice) { |m| notices << m }
    with_stdin(fake) { @tui.read_paste }
    assert(notices.any? { |m| m.include?('paste truncated') })
  end

  def test_normal_paste_round_trips
    fake = FakeInput.new("hello\nworld#{RunesTUI::PASTE_END}")
    notices = []
    @tui.define_singleton_method(:traffic_notice) { |m| notices << m }
    text = with_stdin(fake) { @tui.read_paste }
    assert_equal "hello\nworld", text
    assert_empty notices
  end

  # --- T4-8: publisher connect is bounded ----------------------------------

  def test_publisher_connect_uses_a_bounded_timeout
    captured = nil
    stub = lambda do |*args|
      captured = args.last.is_a?(Hash) ? args.last : {}
      raise 'stop after inspecting options' # avoid a real socket
    end
    MQTT::Client.stub(:connect, stub) do
      @tui.publish_envelope('prompt' => 'hi')
    end
    refute_nil captured, 'publish_envelope must still route through MQTT::Client.connect'
    assert_equal RunesTUI::LIMITS[:pub_connect_s], captured[:connect_timeout]
    assert_operator captured[:connect_timeout], :<=, 5, 'keystroke thread must not block for the 30s default'
  rescue Minitest::Assertion
    raise
  rescue StandardError
    flunk 'publish_envelope must swallow connect failures'
  end

  # --- T4-9: display-column budgeting --------------------------------------

  def test_display_helpers_count_wide_characters_as_two_columns
    assert_equal 4, RunesTUI.display_cols('日本')
    assert_equal 3, RunesTUI.display_cols('a日')
    # display_safe (panels) replaces glyphs; the result is column-bounded.
    assert_equal '???', RunesTUI.display_safe('日本語', 10)
    assert_operator RunesTUI.display_safe('日本語です', 4).length, :<=, 4
    # display_truncate (input rows) keeps glyphs and never splits one.
    assert_equal '日本', RunesTUI.display_truncate('日本語', 4)
    assert_operator RunesTUI.display_cols(RunesTUI.display_truncate('日本語', 5)), :<=, 5
    assert_equal 'ab', RunesTUI.display_truncate('abc', 2)
    assert_equal '', RunesTUI.display_truncate('abc', 0)
  end

  def test_traffic_rows_are_column_budgeted
    row = RunesTUI.display_safe('日' * 40, 20)
    assert_operator row.length, :<=, 20
  end

  def test_cursor_row_never_exceeds_the_frame_width
    width = 40
    %w[short].concat(['日' * 60, 'x' * 200, "a日b\nc"]).each do |text|
      text.split("\n", -1).each do |seg|
        seg.length.times do |cursor|
          rendered = @tui.render_cursor_row(seg, cursor, '> ', width)
          plain = rendered.gsub(/\e\[[0-9;]*m/, '').sub(/\e\[K\z/, '')
          assert_operator RunesTUI.display_cols(plain), :<=, width - 1,
                          "row #{seg.inspect} @#{cursor} overflowed"
        end
      end
    end
  end

  def test_non_cursor_input_rows_are_column_budgeted
    frame = @tui.compose_frame({}, [], :build, nil, "日#{'x' * 300}", 0)
    frame.each_line do |line|
      next unless line.include?("\e[K")

      plain = line.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
      assert_operator RunesTUI.display_cols(plain), :<=, 200
    end
  end

  private

  # Run a block with $stdin swapped and IO.select stubbed for the fake
  # reader (StringIO is not selectable).
  def with_stdin(fake)
    original = $stdin
    $stdin = fake
    IO.stub(:select, ->(ios, *_) { ios.include?(fake) && fake.selectable? ? [ios, nil, nil] : nil }) do
      return yield
    end
  ensure
    $stdin = original
  end
end
