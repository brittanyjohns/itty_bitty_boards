require "base64"

module Boards
  # One board -> one OBF document, plus the assets a packager must write and
  # the ones we refused to bundle.
  #
  # Bundling and the declared license are INDEPENDENT decisions:
  #   * bundling  — per asset, via Images::RedistributionLicense
  #   * license   — per board, derived from what is actually inside
  # A board of a user's own photos bundles every asset AND declares "private",
  # because SpeakAnyWay has no standing to license a user's family photos
  # under an open license on their behalf.
  class ObfExporter
    FORMAT = "open-board-0.1".freeze
    OPEN_LICENSE = { "type" => "CC BY-SA 4.0",
                     "url" => "https://creativecommons.org/licenses/by-sa/4.0/" }.freeze
    PRIVATE_LICENSE = { "type" => "private" }.freeze

    EXTENSIONS_BY_CONTENT_TYPE = {
      "image/png" => "png",
      "image/jpeg" => "jpg",
      "image/gif" => "gif",
      "image/svg+xml" => "svg",
      "image/webp" => "webp",
    }.freeze

    Asset  = Struct.new(:kind, :id, :path, :doc)
    Result = Struct.new(:obf, :assets, :skipped_assets)

    def initialize(board, exporting_user:, asset_mode: :url, board_paths: {})
      @board = board
      @exporting_user = exporting_user
      @asset_mode = asset_mode
      @board_paths = board_paths || {}
      @assets = []
      @skipped_assets = []
      @owned_by_user = false
      @license_types = []
    end

    def call
      tiles = board.board_images.to_a
      images = tiles.map { |tile| image_entry(tile) }
      buttons = tiles.map { |tile| button_entry(tile) }

      obf = {
        "format" => FORMAT,
        "id" => board.id.to_s,
        "locale" => board.language.presence || "en",
        "name" => board.name,
        "default_layout" => "landscape",
        "description_html" => board.description_html,
        "license" => derived_license,
        "grid" => board.format_grid,
        "images" => images,
        "sounds" => tiles.filter_map(&:to_obf_sound_format),
        "buttons" => buttons,
      }

      Result.new(obf, assets, skipped_assets)
    end

    private

    attr_reader :board, :exporting_user, :asset_mode, :board_paths, :assets, :skipped_assets

    def button_entry(tile)
      tile.to_obf_button_format(load_board_path: board_paths[tile.predictive_board_id])
    end

    def image_entry(tile)
      return tile.to_obf_image_format(exporting_user) if asset_mode == :url

      doc = tile.export_doc(exporting_user)
      verdict = doc && Images::RedistributionLicense.for(doc, exporting_user: exporting_user)

      unless verdict&.bundlable?
        skipped_assets << { board_image_id: tile.id, label: tile.label,
                            reason: verdict&.reason || "no image on record" }
        return tile.to_obf_image_format(exporting_user)
      end

      record_license(verdict)
      attach_asset(tile, doc)
    end

    # Reads the bytes for a bundlable asset. A blob we cannot read degrades to a
    # url reference and is recorded — one bad image must never cost the user
    # the whole export.
    def attach_asset(tile, doc)
      return tile.to_obf_image_format(exporting_user) unless doc.image.attached?

      path = "images/#{doc.id}.#{asset_extension(doc)}"

      if asset_mode == :inline
        data = Base64.strict_encode64(doc.image.download)
        return tile.to_obf_image_format(exporting_user, mode: :inline, data: data)
      end

      assets << Asset.new(:image, doc.id.to_s, path, doc)
      tile.to_obf_image_format(exporting_user, mode: :package, path: path)
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] asset unreadable for doc #{doc.id}: #{e.class}: #{e.message}"
      skipped_assets << { board_image_id: tile.id, label: tile.label, reason: "image could not be read" }
      tile.to_obf_image_format(exporting_user)
    end

    # NOT Doc#extension: that reads `original_image_url`, which is nil for
    # user uploads (only the download-from-URL paths set it) and keeps query
    # strings when present. Read the blob instead, which is always right for an
    # attached asset.
    def asset_extension(doc)
      ext = doc.image.filename.extension.presence
      return ext.downcase if ext.present?

      EXTENSIONS_BY_CONTENT_TYPE.fetch(doc.image.content_type, "png")
    end

    def record_license(verdict)
      @owned_by_user ||= verdict.owned_by_user?
      @license_types << verdict.type if verdict.type.present?
    end

    # Any content the user owns makes the board theirs, not ours to license.
    # Otherwise fall back to the open license only when nothing carried a more
    # restrictive one.
    def derived_license
      return PRIVATE_LICENSE if @owned_by_user
      return OPEN_LICENSE if @license_types.empty?

      { "type" => @license_types.uniq.sort.last }
    end
  end
end
