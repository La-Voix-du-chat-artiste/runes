# frozen_string_literal: true

module Runes
  # Runtime primitives that Ruby-runtimes-with-a-subset (Spinel) lack, in
  # portable, dependency-free form. Every method here is implemented from
  # File/Dir/Time and integer arithmetic only, so the same code path runs
  # under CRuby and under a compiled kernel.
  #
  # Where a platform offers a better native primitive (CLOCK_MONOTONIC,
  # Time#iso8601) CRuby parity is preserved by construction: the portable
  # implementations below produce the same observable output.
  module Compat
    # FileUtils.mkdir_p equivalent: create dir and parents; EEXIST/no-op safe.
    def self.mkdir_p(dir)
      path = dir.to_s
      return if path.empty? || File.directory?(path)

      begin
        Dir.mkdir(path)
      rescue Errno::ENOENT
        parent = path.sub(%r{/[^/]+/?\z}, '')
        parent = path.start_with?('/') ? '/' : '.' if parent.empty?
        mkdir_p(parent)
        begin
          Dir.mkdir(path)
        rescue Errno::EEXIST
          nil
        end
      rescue Errno::EEXIST
        nil
      end
    end

    # FileUtils.rm_rf equivalent for a directory tree (self-check cleanup).
    def self.rm_rf(path)
      return unless File.directory?(path)

      Dir.glob(File.join(path, '*')).each do |entry|
        if File.directory?(entry)
          rm_rf(entry)
        else
          File.delete(entry)
        end
      end
      Dir.delete(path)
    rescue SystemCallError
      nil
    end

    # File.basename equivalent for POSIX '/'-separated paths. Command-policy
    # tokens are grammar-checked before this is ever called, so the exotic
    # File.basename corner cases (trailing slashes on the empty string) do
    # not apply; '/'-separation is the whole contract on POSIX.
    def self.basename(path)
      text = path.to_s.sub(%r{/+\z}, '')
      parts = text.split('/')
      parts.empty? ? '' : parts.last
    end

    # UTC civil date (YYYY-MM-DD) from epoch seconds via the
    # Howard-Hinnant civil_from_days algorithm. No Date/stdx needed, and
    # identical under every runtime (Date.today is local time; this is UTC
    # on purpose — see docs/spinel/spec-tier-a.md §Delivered-state deltas).
    def self.utc_date(time = nil)
      seconds = time.nil? ? Time.now.to_i : time.to_i
      y, m, d = civil(seconds / 86_400)
      pad_left(y, 4) + '-' + pad_left(m, 2) + '-' + pad_left(d, 2)
    end

    # ISO-8601 UTC timestamp with milliseconds, e.g. 2026-09-30T12:34:56.789Z.
    # Computed from Time#to_i/Time#to_f arithmetic only — no strftime, no
    # 'time' stdlib — so it behaves identically under CRuby and Spinel.
    def self.utc_iso8601(time, millis: true)
      seconds = time.to_i
      days, secs = seconds / 86_400, seconds % 86_400
      y, mo, d = civil(days)
      hh = (secs / 3600) % 24
      mi = (secs / 60) % 60
      ss = secs % 60
      stamp = pad_left(y, 4) + '-' + pad_left(mo, 2) + '-' + pad_left(d, 2) +
              'T' + pad_left(hh, 2) + ':' + pad_left(mi, 2) + ':' + pad_left(ss, 2)
      if millis
        fraction = time.to_f - seconds
        stamp + '.' + pad_left(((fraction * 1000).round % 1000), 3) + 'Z'
      else
        stamp + 'Z'
      end
    end

    # A plain-Hash snapshot of the process environment. Spinel models ENV as
    # a call receiver only (ENV["KEY"] works; ENV-as-a-value does not), so
    # anything that needs the whole environment reads it through this.
    def self.env_snapshot
      out = {}
      if defined?(ENV) && ENV.respond_to?(:each_pair)
        ENV.each_pair { |key, value| out[key] = value }
      end
      out
    end

    # Monotonic seconds. CRuby: CLOCK_MONOTONIC. A runtime without Process
    # (a compiled kernel) falls back to wall clock — TTL logic stays
    # correct, only the monotonicity guarantee weakens (spec-tier-a §Facades).
    def self.monotonic
      if defined?(Process) && Process.respond_to?(:clock_gettime)
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      else
        Time.now.to_f
      end
    rescue StandardError
      Time.now.to_f
    end

    # --- byte / encoding primitives ---------------------------------------

    # The binary (ASCII-8BIT) form of a string. A no-op on a runtime without
    # an encoding model (the Spinel kernel); under CRuby it forces BINARY so
    # byte-oriented building never trips an Encoding::CompatibilityError.
    def self.binary(str)
      text = str.to_s
      return text unless defined?(Encoding)

      text.dup.force_encoding(Encoding::BINARY)
    end

    # A string of the given byte values (0-255). `String#pack` with the C/Q
    # directives references runtime internals that are not stable across
    # whole-program builds; Integer#chr is the portable primitive.
    def self.byte_string(ints)
      out = String.new
      ints.each do |b|
        out << (b.to_i & 0xff).chr
      end
      out
    end

    HEX_DIGITS = '0123456789abcdef'

    # Lowercase hex of a byte string (String#unpack('H*') equivalent).
    def self.hex_encode(bytes)
      data = bytes.to_s
      out = String.new
      i = 0
      n = data.bytesize
      while i < n
        b = data.getbyte(i)
        out << HEX_DIGITS[b >> 4] << HEX_DIGITS[b & 15]
        i += 1
      end
      out
    end

    # Bytes from lowercase/uppercase hex (Array#pack('H*') equivalent).
    def self.hex_decode(hex)
      text = hex.to_s
      raise ArgumentError, 'malformed hex length' unless text.length % 2 == 0

      out = String.new
      i = 0
      while i < text.length
        hi = HEX_DIGITS.index(text[i].downcase)
        lo = HEX_DIGITS.index(text[i + 1].downcase)
        raise ArgumentError, 'malformed hex digit' if hi.nil? || lo.nil?

        out << ((hi << 4) | lo).chr
        i += 2
      end
      out
    end

    B64_DIGITS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

    # Strict RFC 4648 base64 with padding (Array#pack('m0') equivalent).
    def self.base64_encode(bytes)
      data = bytes.to_s
      out = String.new
      i = 0
      n = data.bytesize
      while i < n
        b0 = data.getbyte(i)
        b1 = i + 1 < n ? data.getbyte(i + 1) : 0
        b2 = i + 2 < n ? data.getbyte(i + 2) : 0
        trip = (b0 << 16) | (b1 << 8) | b2
        out << B64_DIGITS[(trip >> 18) & 63]
        out << B64_DIGITS[(trip >> 12) & 63]
        out << (i + 1 < n ? B64_DIGITS[(trip >> 6) & 63] : '=')
        out << (i + 2 < n ? B64_DIGITS[trip & 63] : '=')
        i += 3
      end
      out
    end

    # Base64 decode; accepts embedded whitespace, requires correct padding.
    def self.base64_decode(text)
      clean = text.to_s.gsub(/\s+/, '')
      raise ArgumentError, 'malformed base64 length' unless clean.length % 4 == 0

      out = String.new
      i = 0
      n = clean.length
      while i < n
        c0 = clean[i]
        c1 = clean[i + 1]
        c2 = clean[i + 2]
        c3 = clean[i + 3]
        v0 = B64_DIGITS.index(c0)
        v1 = B64_DIGITS.index(c1)
        raise ArgumentError, 'malformed base64 digit' if v0.nil? || v1.nil?

        v2 = c2 == '=' ? 0 : B64_DIGITS.index(c2)
        v3 = c3 == '=' ? 0 : B64_DIGITS.index(c3)
        raise ArgumentError, 'malformed base64 digit' if v2.nil? || v3.nil?

        trip = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3
        out << ((trip >> 16) & 0xff).chr
        out << ((trip >> 8) & 0xff).chr unless c2 == '='
        out << (trip & 0xff).chr unless c3 == '='
        i += 4
      end
      out
    end

    # Left-pad with `ch` to width (Kernel#format/rjust equivalents, kept
    # dependency-free for the same whole-program-build reason as above).
    def self.pad_left(text, width, ch = '0')
      s = text.to_s
      s = ch + s while s.length < width
      s
    end

    # The UTF-8 encoding of a Unicode codepoint as a String, without naming
    # Encoding constants (a runtime without an encoding model — the Spinel
    # kernel — still builds exactly these bytes).
    def self.utf8_char(code)
      point = code.to_i
      bytes =
        if point < 0x80
          [point]
        elsif point < 0x800
          [0xC0 | (point >> 6), 0x80 | (point & 0x3F)]
        elsif point < 0x10000
          [0xE0 | (point >> 12), 0x80 | ((point >> 6) & 0x3F), 0x80 | (point & 0x3F)]
        else
          [0xF0 | (point >> 18), 0x80 | ((point >> 12) & 0x3F),
           0x80 | ((point >> 6) & 0x3F), 0x80 | (point & 0x3F)]
        end
      packed = byte_string(bytes)
      return packed unless defined?(Encoding)

      packed.force_encoding(Encoding::UTF_8)
    end

    # config/.env parsing. Delegates to the dotenv gem when it is loaded
    # (CRuby harness — identical behavior to before); falls back to a pure
    # subset parser (KEY=VALUE lines, optional `export`, optional matching
    # single/double quotes, comments and blanks skipped; no ${VAR}
    # interpolation — the fallback is for the compiled kernel, whose .env
    # files this project controls).
    def self.parse_dotenv(path)
      return Dotenv.parse(path) if defined?(Dotenv) && Dotenv.respond_to?(:parse)

      out = {}
      return out unless File.file?(path)

      File.read(path).each_line do |line|
        text = line.strip
        next if text.empty? || text.start_with?('#')

        text = text.sub(/\Aexport\s+/, '')
        key, _, value = text.partition('=')
        key = key.strip
        next if key.empty?

        value = value.strip
        if value.length >= 2 && (value.start_with?('"') && value.end_with?('"') || value.start_with?("'") && value.end_with?("'"))
          value = value[1..-2]
        end
        out[key] = value
      end
      out
    end

    # Days since 1970-01-01 -> [year, month, day] (proleptic Gregorian).
    # Howard-Hinnant civil_from_days; Ruby integer division floors, which is
    # exactly what the algorithm needs for the era computation.
    def self.civil(days)
      z = days + 719_468
      era = z / 146_097
      doe = z - era * 146_097                      # [0, 146096]
      y = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365 # [0, 399]
      doy = doe - (365 * y + y / 4 - y / 100)      # [0, 365]
      mp = (5 * doy + 2) / 153                     # [0, 11]
      d = doy - (153 * mp + 2) / 5 + 1
      m = mp + (mp < 10 ? 3 : -9)
      [era * 400 + y + (m <= 2 ? 1 : 0), m, d]
    end
  end
end
