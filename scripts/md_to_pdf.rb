# frozen_string_literal: true

# Renders a markdown document to a designed PDF.
#
#   ruby scripts/md_to_pdf.rb docs/WHY_RUNES.md docs/WHY_RUNES.pdf
#
# Why a renderer and not a hand-built deck: the PDF is meant to be the SAME
# text as the markdown, so a claim cannot be true in one and stale in the
# other. Handles the subset these docs actually use — headings, paragraphs,
# bullets, numbered items, fenced code, tables, blockquotes, rules, and inline
# **bold** / `code` / [links](url) — and nothing else.

require "prawn"
require "prawn/table"
require "cgi"

INK       = "0B1220"
PRIMARY   = "0E7490" # cyan-700
SECONDARY = "7C3AED" # violet-600
WARM      = "D97706" # amber-600
GOOD      = "047857" # emerald-700
MUTED     = "64748B"
PANEL     = "F1F5F9"
ZEBRA     = "F8FAFC"
BORDER    = "CBD5E1"
CODE_INK  = "0F766E"

BODY_FONTS = {
  normal: "/System/Library/Fonts/Supplemental/Arial.ttf",
  bold: "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
  italic: "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
  bold_italic: "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf"
}.freeze
MONO_FONTS = {
  normal: "/System/Library/Fonts/Supplemental/Courier New.ttf",
  bold: "/System/Library/Fonts/Supplemental/Courier New Bold.ttf"
}.freeze

# A few glyphs in these docs come from fonts Prawn cannot embed.
SUBSTITUTIONS = {
  "🌀" => "", "◈" => "*", "✅" => "yes", "✔" => "yes", "✕" => "x",
  "→" => "->", "←" => "<-", "↔" => "<->", "·" => "-", "≈" => "~",
  "≤" => "<=", "≥" => ">=", "—" => "-", "–" => "-", "…" => "...",
  "±" => "+/-", "×" => "x", "“" => '"', "”" => '"', "’" => "'", "‘" => "'"
}.freeze

# Prawn flows plain text across page breaks, but bounding boxes, tables and
# code panels do not: drawn too low they clip off the page and leave a page
# carrying nothing but the footer (found by rendering this document and reading
# it back). Break *before* drawing when the room is not there.
def ensure_room(pdf, needed)
  return if pdf.cursor >= needed && pdf.cursor.positive?

  pdf.start_new_page
end

def scrub(text)
  out = text.to_s.dup
  SUBSTITUTIONS.each { |from, to| out = out.gsub(from, to) }
  out.each_char.reject { |c| c.ord > 0x2FFF }.join # drop emoji/PUA remnants
end

# Escape for Prawn's inline markup, then apply markdown -> prawn tags.
def inline(text)
  s = CGI.escapeHTML(scrub(text))
  # Prawn's inline parser decodes &lt; &gt; &amp; but NOT &quot;/&#39;, which then
  # render literally. Quotes need no escaping inside its markup, so put them
  # back and let <id> and & survive.
  s = s.gsub("&quot;", '"').gsub("&#39;", "'")
  s = s.gsub(/\*\*(.+?)\*\*/m) { "<b>#{Regexp.last_match(1)}</b>" }
  s = s.gsub(/`([^`]+)`/) { "<font name=\"mono\" color=\"#{CODE_INK}\">#{Regexp.last_match(1)}</font>" }
  s = s.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
    "<link href=\"#{Regexp.last_match(2)}\"><color rgb=\"#{PRIMARY}\">#{Regexp.last_match(1)}</color></link>"
  end
  s
end

# --- block parser -----------------------------------------------------------

Block = Struct.new(:type, :level, :text, :rows, :lines, keyword_init: true)

def parse(markdown)
  blocks = []
  lines = markdown.lines.map(&:chomp)
  index = 0
  while index < lines.length
    line = lines[index]
    before = index
    case line
    when /\A```/
      index += 1
      code = []
      while index < lines.length && !lines[index].start_with?("```")
        code << lines[index]
        index += 1
      end
      index += 1
      blocks << Block.new(type: :code, lines: code)
    when /\A(\#{1,6})\s+(.*)\z/
      blocks << Block.new(type: :heading, level: Regexp.last_match(1).length, text: Regexp.last_match(2))
      index += 1
    when /\A---+\s*\z/
      blocks << Block.new(type: :rule)
      index += 1
    when /\A>\s?(.*)\z/
      quote = []
      while index < lines.length && lines[index].match?(/\A>\s?/)
        quote << lines[index].sub(/\A>\s?/, "")
        index += 1
      end
      blocks << Block.new(type: :quote, text: quote.join(" "))
    when /\A\|/
      rows = []
      while index < lines.length && lines[index].start_with?("|")
        # `split("|", -1)`: the -1 keeps the trailing empty field Ruby drops
        # by default. Without it a `| a | b |` row splits into three fields,
        # `[1..-2]` keeps only `a`, and EVERY table in the PDF silently loses
        # its value column — which is exactly what shipped in the first
        # version of this renderer.
        cells = lines[index].split("|", -1)[1..-2].to_a.map(&:strip)
        rows << cells unless cells.all? { |c| c.match?(/\A:?-{2,}:?\z/) }
        index += 1
      end
      widths = rows.map(&:size).uniq
      if widths.size > 1
        raise "markdown table has ragged rows #{widths.inspect} at line #{index} " \
              "(a row is missing a cell or a trailing `|`)"
      end
      blocks << Block.new(type: :table, rows: rows)
    when /\A[-*]\s+(.*)\z/
      blocks << Block.new(type: :bullet, text: Regexp.last_match(1))
      index += 1
    when /\A\s*\z/
      index += 1
    else
      para = [line]
      index += 1
      while index < lines.length && !lines[index].strip.empty? &&
            !lines[index].match?(/\A(#|\||>|```|---|\s*[-*]\s)/)
        para << lines[index]
        index += 1
      end
      blocks << Block.new(type: :para, text: para.join(" "))
    end

    # A parser that stops advancing is a hang, and a hang is the worst way to
    # learn about a grammar case you forgot: say which line instead.
    raise "markdown parser stalled at line #{before + 1}: #{line.inspect}" if index == before
  end
  blocks
end

# --- renderer ---------------------------------------------------------------

def render(markdown, out_path)
  blocks = parse(markdown)
  title = blocks.find { |b| b.type == :heading && b.level == 1 }&.text || "Runes"

  Prawn::Document.generate(out_path, page_size: "A4", margin: [44, 48, 52, 48]) do |pdf|
    pdf.font_families.update("body" => BODY_FONTS) if File.exist?(BODY_FONTS[:normal])
    pdf.font_families.update("mono" => MONO_FONTS) if File.exist?(MONO_FONTS[:normal])
    pdf.font("body")
    pdf.default_leading 3

    # --- cover band ------------------------------------------------------
    top = pdf.bounds.top
    pdf.fill_color PRIMARY
    pdf.fill_rectangle [0, top], pdf.bounds.width * 0.5, 5
    pdf.fill_color SECONDARY
    pdf.fill_rectangle [pdf.bounds.width * 0.5, top], pdf.bounds.width * 0.3, 5
    pdf.fill_color WARM
    pdf.fill_rectangle [pdf.bounds.width * 0.8, top], pdf.bounds.width * 0.2, 5

    pdf.move_down 22
    pdf.fill_color INK
    pdf.text(scrub(title.sub(/\AWhy Runes.*\z/, "Why Runes")), size: 30, style: :bold, inline_format: false)
    pdf.move_down 2
    pdf.fill_color PRIMARY
    pdf.text("A Ruby agent harness with a fabric, an identity, a memory and a face",
             size: 12.5, style: :bold)
    pdf.move_down 6
    pdf.fill_color MUTED
    pdf.text("Runes 0.3.0  |  #{Time.now.strftime('%d %B %Y')}  |  " \
             "github.com/runes-harness/runes", size: 9)
    pdf.move_down 14

    # The document's H1 is the cover title, so it is not repeated in the flow.
    skip_title = true
    blocks.each do |block|
      case block.type
      when :heading
        if block.level == 1 && skip_title
          skip_title = false
          next
        end

        # Keep a heading with at least a couple of lines under it.
        ensure_room(pdf, 64)
        case block.level
        when 2
          pdf.move_down 14
          y = pdf.cursor
          pdf.fill_color PRIMARY
          pdf.fill_rectangle [0, y], 3, 15
          pdf.fill_color INK
          pdf.text_box(scrub(block.text), at: [11, y], size: 15.5, style: :bold)
          pdf.move_down 22
          pdf.stroke_color BORDER
          pdf.stroke_horizontal_line 0, pdf.bounds.width
          pdf.move_down 8
        when 3
          pdf.move_down 8
          pdf.fill_color SECONDARY
          pdf.text(scrub(block.text), size: 12, style: :bold)
          pdf.move_down 3
        else
          pdf.move_down 5
          pdf.fill_color INK
          pdf.text(scrub(block.text), size: 10.5, style: :bold)
        end

      when :para
        next if block.text.strip.empty?

        ensure_room(pdf, 38)
        pdf.fill_color INK
        pdf.text(inline(block.text), size: 10, leading: 2.5, inline_format: true)
        pdf.move_down 5

      when :bullet
        ensure_room(pdf, 34)
        pdf.fill_color PRIMARY
        pdf.bounding_box([0, pdf.cursor], width: 10, height: 12) { pdf.text("-", size: 10, style: :bold) }
        pdf.bounding_box([12, pdf.cursor + 12], width: pdf.bounds.width - 12) do
          pdf.fill_color INK
          pdf.text(inline(block.text), size: 10, leading: 2.5, inline_format: true)
        end
        pdf.move_down 3

      when :quote
        ensure_room(pdf, 60)
        pdf.move_down 4
        pdf.table([[inline(block.text)]],
                  width: pdf.bounds.width, cell_style: {
                    background_color: ZEBRA, borders: [:left], border_width: 3,
                    border_color: WARM, padding: [8, 10, 8, 10], size: 10,
                    inline_format: true, text_color: INK
                  })
        pdf.move_down 8

      when :code
        ensure_room(pdf, 70)
        pdf.move_down 4
        pdf.table([[scrub(block.lines.join("\n"))]],
                  width: pdf.bounds.width, cell_style: {
                    background_color: PANEL, borders: [:left], border_width: 3,
                    border_color: PRIMARY, padding: [8, 10, 8, 10],
                    font: "mono", size: 8.4, text_color: CODE_INK, leading: 1.5
                  })
        pdf.move_down 8

      when :table
        next if block.rows.empty?

        ensure_room(pdf, 80)
        pdf.move_down 4
        pdf.table(block.rows, width: pdf.bounds.width, header: true, cell_style: {
                    size: 9, padding: [6, 8, 6, 8], border_color: BORDER, borders: [:bottom],
                    inline_format: true, text_color: INK
                  }) do
          row(0).background_color = PRIMARY
          row(0).text_color = "FFFFFF"
          row(0).font_style = :bold
          rows(1..-1).each_with_index { |row, i| row.background_color = ZEBRA if i.odd? }
        end
        pdf.move_down 8

      when :rule
        pdf.move_down 6
        pdf.stroke_color BORDER
        pdf.stroke_horizontal_line 0, pdf.bounds.width
        pdf.move_down 6
      end
    end

    # --- footer ----------------------------------------------------------
    pdf.number_pages("<color rgb='#{MUTED}'>Why Runes - page <page> of <total></color>",
                     at: [0, -32], align: :center, size: 8.5, inline_format: true)
  end
  check_blank_pages(out_path)
  out_path
end

# A page with nothing but the footer is a rendering bug, not a style choice:
# the text was drawn past the bottom and clipped. Fail loudly rather than ship
# a PDF with holes in it.
def check_blank_pages(path)
  require "pdf-reader"
  reader = PDF::Reader.new(path)
  blank = reader.pages.each_with_index.select do |page, _index|
    page.text.to_s.gsub(/Why Runes - page \d+ of \d+/, "").strip.empty?
  end.map { |_page, index| index + 1 }
  warn "md_to_pdf: WARNING blank page(s) #{blank.inspect} in #{path}" unless blank.empty?
  blank
rescue LoadError
  warn "md_to_pdf: pdf-reader not installed; skipping the blank-page check"
  []
rescue StandardError => e
  warn "md_to_pdf: could not check #{path} (#{e.class}: #{e.message})"
  []
end

if $PROGRAM_NAME == __FILE__
  source = ARGV[0] or abort("usage: md_to_pdf.rb INPUT.md OUTPUT.pdf")
  out = ARGV[1] || source.sub(/\.md\z/, ".pdf")
  render(File.read(source), out)
  puts "wrote #{out} (#{File.size(out)} bytes)"
end
