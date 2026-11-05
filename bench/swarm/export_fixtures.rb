# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'

# Copy the synthetic media fixtures to a portable directory.
#
#   ruby bench/swarm/export_fixtures.rb --out /tmp/swarm-fixtures
#
# The export contains the media files, a freshly written `index.json`
# (name, sha256, bytes, modality, cases) and `SOURCES.md`. When the repo's
# own `fixtures/index.json` exists, every copied file is verified against it,
# so a corrupted fixture cannot travel. The benchmark itself never reads the
# export; this is for sharing the 24 cases without the repo.
module Runes
  module Bench
    module Swarm
      class FixtureExport
        class Error < StandardError; end

        FIXTURES = File.expand_path('fixtures', __dir__)
        MEDIA_EXT = %w[.png .wav .mp4 .jpg .jpeg .webm .mov].freeze

        MODALITY = {
          '.png' => 'image', '.jpg' => 'image', '.jpeg' => 'image',
          '.wav' => 'audio', '.mp3' => 'audio', '.ogg' => 'audio',
          '.mp4' => 'audio-video', '.webm' => 'audio-video', '.mov' => 'audio-video'
        }.freeze

        attr_reader :out_dir

        def self.run(argv)
          new.parse(argv).export
          0
        rescue Error, OptionParser::ParseError => e
          warn "error: #{e.message}"
          2
        end

        def parse(argv)
          @out_dir = nil
          OptionParser.new do |opts|
            opts.banner = 'Usage: ruby bench/swarm/export_fixtures.rb --out DIR'
            opts.on('--out DIR', 'Portable export directory (required)') { |value| @out_dir = value }
            opts.on('-h', '--help', 'Show this help') do
              puts opts
              exit 0
            end
          end.parse!(argv)
          raise Error, '--out is required' if @out_dir.to_s.empty?

          self
        end

        def media_files
          Dir.children(FIXTURES).sort.select do |name|
            MEDIA_EXT.include?(File.extname(name).downcase)
          end
        end

        def cases_by_media
          cases_path = File.expand_path('cases.json', __dir__)
          data = JSON.parse(File.read(cases_path))
          cases = data.is_a?(Hash) ? (data['cases'] || []) : data
          cases.each_with_object({}) do |spec, out|
            Array(spec['media']).each do |relative|
              name = File.basename(relative.to_s)
              (out[name] ||= []) << spec['id']
            end
          end
        end

        def index
          used = cases_by_media
          {
            'format' => 'swarm-fixtures-v1',
            'generated_at' => Time.now.utc.strftime('%Y-%m-%d'),
            'license' => 'Synthetic fixtures, CC0-1.0',
            'files' => media_files.map do |name|
              path = File.join(FIXTURES, name)
              {
                'name' => name,
                'sha256' => Digest::SHA256.file(path).hexdigest,
                'bytes' => File.size(path),
                'modality' => MODALITY.fetch(File.extname(name).downcase, 'unknown'),
                'cases' => used.fetch(name, [])
              }
            end
          }
        end

        def export
          reference = load_reference_index
          FileUtils.mkdir_p(@out_dir)
          written = []
          index['files'].each do |entry|
            src = File.join(FIXTURES, entry['name'])
            dst = File.join(@out_dir, entry['name'])
            FileUtils.cp(src, dst)
            actual = Digest::SHA256.file(dst).hexdigest
            if reference && reference[entry['name']] && reference[entry['name']] != actual
              raise Error, "#{entry['name']}: sha256 mismatch after copy " \
                           "(expected #{reference[entry['name']]}, got #{actual})"
            end
            written << dst
          end
          File.write(File.join(@out_dir, 'index.json'), JSON.pretty_generate(index) + "\n")
          sources = File.join(FIXTURES, 'SOURCES.md')
          FileUtils.cp(sources, File.join(@out_dir, 'SOURCES.md')) if File.file?(sources)
          written << File.join(@out_dir, 'index.json')
          written.each { |path| puts path }
          written
        end

        private

        def load_reference_index
          path = File.join(FIXTURES, 'index.json')
          return nil unless File.file?(path)

          data = JSON.parse(File.read(path))
          Array(data['files']).each_with_object({}) do |entry, out|
            out[entry['name']] = entry['sha256']
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit Runes::Bench::Swarm::FixtureExport.run(ARGV)
end
