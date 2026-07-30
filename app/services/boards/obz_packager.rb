require "zip"
require "json"
require "stringio"

module Boards
  # Writes a .obz package. The layout mirrors exactly what ObzImporter reads —
  # manifest["root"] plus manifest["paths"]["boards"] — so an exported package
  # re-imports cleanly. Changing the layout here without changing ObzImporter
  # breaks the round-trip spec, which is the point of that spec.
  class ObzPackager
    class TooLarge < StandardError; end

    FORMAT = "open-board-0.1".freeze

    # Belt to ExportScope::MAX_BOARDS' braces: a small number of boards can
    # still carry very large images. Fails with an explicit error rather than
    # letting the job die on memory or the upload time out.
    MAX_BYTES = 200 * 1024 * 1024

    Result = Struct.new(:bytes, :summary)

    def initialize(scope_result, exporting_user:)
      @scope = scope_result
      @exporting_user = exporting_user
    end

    def call
      board_paths = scope.boards.to_h { |board| [board.id, "boards/#{board.id}.obf"] }

      exports = scope.boards.map do |board|
        [board, ObfExporter.new(board, exporting_user: exporting_user,
                                       asset_mode: :package, board_paths: board_paths).call]
      end

      bytes = build_zip(exports, board_paths)
      raise TooLarge, "Package exceeds the #{MAX_BYTES / 1024 / 1024}MB limit" if bytes.bytesize > MAX_BYTES

      Result.new(bytes, summarize(exports))
    end

    private

    attr_reader :scope, :exporting_user

    def build_zip(exports, board_paths)
      buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
        exports.each do |board, result|
          zip.put_next_entry(board_paths[board.id])
          zip.write(JSON.pretty_generate(result.obf))
        end

        written = write_assets(zip, exports)

        zip.put_next_entry("manifest.json")
        zip.write(JSON.pretty_generate(manifest(exports, board_paths, written)))

        readme = readme_text(exports)
        if readme
          zip.put_next_entry("README.txt")
          zip.write(readme)
        end
      end

      buffer.string.force_encoding(Encoding::BINARY)
    end

    # Assets are deduplicated by path: the same doc can back tiles on several
    # boards, and a zip must not contain the same entry twice.
    def write_assets(zip, exports)
      seen = {}

      exports.each do |_board, result|
        result.assets.each do |asset|
          next if seen.key?(asset.path)

          seen[asset.path] = asset.id
          zip.put_next_entry(asset.path)
          zip.write(asset.doc.image.download)
        end
      end

      seen
    end

    def manifest(exports, board_paths, written_assets)
      boards = exports.to_h { |board, _| [board.id.to_s, board_paths[board.id]] }
      images = written_assets.to_h { |path, id| [id, path] }

      {
        "format" => FORMAT,
        "root" => board_paths[scope.root&.id] || board_paths.values.first,
        "paths" => { "boards" => boards, "images" => images, "sounds" => {} },
      }
    end

    def summarize(exports)
      {
        "bundled_assets" => exports.sum { |_b, r| r.assets.size },
        "skipped_assets" => exports.flat_map { |_b, r| r.skipped_assets },
        "skipped_boards" => scope.skipped_boards,
        "licenses" => exports.map { |_b, r| r.obf["license"]["type"] }.uniq,
        "exported_by_user_id" => exporting_user&.id,
        "exported_at" => Time.current.iso8601,
      }
    end

    def readme_text(exports)
      skipped_assets = exports.flat_map { |_b, r| r.skipped_assets }
      return nil if skipped_assets.empty? && scope.skipped_boards.empty?

      lines = ["This package was exported from SpeakAnyWay (https://speakanyway.com).", ""]

      if skipped_assets.any?
        lines << "Some images are referenced by link rather than included as files:"
        skipped_assets.each { |a| lines << "  - #{a[:label]}: #{a[:reason]}" }
        lines << ""
      end

      if scope.skipped_boards.any?
        lines << "Some linked boards were not included:"
        scope.skipped_boards.each { |b| lines << "  - board #{b[:board_id]}: #{b[:reason]}" }
        lines << ""
      end

      lines.join("\n")
    end
  end
end
