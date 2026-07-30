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
    class TooLarge < StandardError; end

    FORMAT = "open-board-0.1".freeze
    OPEN_LICENSE = { "type" => "CC BY-SA 4.0",
                     "url" => "https://creativecommons.org/licenses/by-sa/4.0/" }.freeze
    PRIVATE_LICENSE = { "type" => "private" }.freeze

    # Only enforced for asset_mode: :inline (the synchronous GET /download_obf
    # path, which base64-encodes every image into one in-memory response
    # inside a Puma worker). :package and :url modes are unaffected — :package
    # goes through the async ExportBoardPackageJob + Boards::ObzPackager,
    # which has its own MAX_BYTES cap on the whole .obz.
    MAX_INLINE_TILES = 200
    MAX_INLINE_BYTES = 20 * 1024 * 1024

    EXTENSIONS_BY_CONTENT_TYPE = {
      "image/png" => "png",
      "image/jpeg" => "jpg",
      "image/gif" => "gif",
      "image/svg+xml" => "svg",
      "image/webp" => "webp",
    }.freeze

    Asset  = Struct.new(:kind, :id, :path, :doc)
    Result = Struct.new(:obf, :assets, :skipped_assets, :attribution)

    def initialize(board, exporting_user:, asset_mode: :url, board_paths: {})
      @board = board
      @exporting_user = exporting_user
      @asset_mode = asset_mode
      @board_paths = board_paths || {}
      @assets = []
      @skipped_assets = []
      @attribution = []
      @owned_by_user = false
      @license_types = []
      @evaluated_bundlable = false
    end

    def call
      # sound_entry resolves audio off BOTH the tile's own audio_files and
      # (as a fallback) the image's audio_files — preload both sides'
      # attachments/blobs or each tile falls back to its own per-tile query
      # (mirrors the :audio_files_attachments/:audio_files_blobs pairing
      # already used for `image:` eager-loads elsewhere, e.g. Board's
      # includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, ...] })).
      tiles = board.board_images.includes(
        :board, :audio_files_attachments, :audio_files_blobs,
        image: [:audio_files_attachments, :audio_files_blobs]
      ).to_a

      if asset_mode == :inline && tiles.size > MAX_INLINE_TILES
        raise TooLarge, "Board has #{tiles.size} tiles, over the #{MAX_INLINE_TILES}-tile sync export limit"
      end

      predictive_ids = tiles.filter_map(&:predictive_board_id).uniq
      boards_by_id = Board.where(id: predictive_ids).index_by(&:id)

      image_ids = tiles.filter_map(&:image_id).uniq
      @preloaded_user_docs = if exporting_user
          exporting_user.user_docs.includes(:doc).where(image_id: image_ids).group_by(&:image_id)
        else
          nil
        end

      images = tiles.map { |tile| image_entry(tile) }
      buttons = tiles.map { |tile| button_entry(tile, boards_by_id) }

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
        "sounds" => tiles.filter_map { |tile| sound_entry(tile) },
        "buttons" => buttons,
      }

      Result.new(obf, assets, skipped_assets, attribution)
    end

    private

    attr_reader :board, :exporting_user, :asset_mode, :board_paths, :assets, :skipped_assets, :attribution

    def button_entry(tile, boards_by_id)
      tile.to_obf_button_format(load_board_path: board_paths[tile.predictive_board_id], boards_by_id: boards_by_id)
    end

    def image_entry(tile)
      return tile.to_obf_image_format(exporting_user) if asset_mode == :url

      doc = tile.export_doc(exporting_user, preloaded_user_docs: @preloaded_user_docs)
      verdict = doc && Images::RedistributionLicense.for(doc, exporting_user: exporting_user)

      unless verdict&.bundlable?
        skipped_assets << { board_image_id: tile.id, label: tile.label,
                            reason: verdict&.reason || "no image on record" }
        content_type = doc.image.content_type if doc&.image&.attached?
        return tile.to_obf_image_format(exporting_user, content_type: content_type)
      end

      record_license(verdict, tile)
      attach_asset(tile, doc)
    end

    # Reads the bytes for a bundlable asset. A blob we cannot read degrades to a
    # url reference and is recorded — one bad image must never cost the user
    # the whole export.
    def attach_asset(tile, doc)
      return tile.to_obf_image_format(exporting_user) unless doc.image.attached?

      path = "images/#{doc.id}.#{asset_extension(doc)}"

      if asset_mode == :inline
        bytes = doc.image.download
        @inline_bytes_total = (@inline_bytes_total || 0) + bytes.bytesize
        if @inline_bytes_total > MAX_INLINE_BYTES
          raise TooLarge, "Inline export exceeds #{MAX_INLINE_BYTES / 1024 / 1024}MB, over the sync export size limit"
        end

        data = Base64.strict_encode64(bytes)
        return tile.to_obf_image_format(exporting_user, mode: :inline, data: data, content_type: doc.image.content_type)
      end

      assets << Asset.new(:image, doc.id.to_s, path, doc)
      tile.to_obf_image_format(exporting_user, mode: :package, path: path, content_type: doc.image.content_type)
    rescue TooLarge
      raise
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] asset unreadable for doc #{doc.id}: #{e.class}: #{e.message}"
      skipped_assets << { board_image_id: tile.id, label: tile.label, reason: "image could not be read" }
      tile.to_obf_image_format(exporting_user)
    end

    # Sound bundling mirrors image bundling's shape but skips
    # Images::RedistributionLicense entirely: unlike images, no code path
    # today attaches third-party audio to audio_files — every attachment is
    # either SpeakAnyWay's own Polly/OpenAI TTS synthesis or the user's own
    # custom upload (has_custom_audio?). Bundling is therefore unconditional.
    # Revisit if an audio-import path is ever built.
    def sound_entry(tile)
      return tile.to_obf_sound_format if asset_mode == :url

      # current_audio_attachment returns a single ActiveStorage::Attachment
      # record (or nil), not the has_many_attached proxy — #attached? is a
      # proxy-only method (record.audio_files.attached?), so a plain
      # presence check is the correct guard here.
      #
      # Two distinct places carry audio: the shared Image's own audio_files
      # (Polly/OpenAI TTS, attached via AudioHelper#save_audio_file) and this
      # tile's OWN audio_files (a per-tile custom recording/upload, attached
      # via BoardImagesController#upload_audio — see BoardImage#has_custom_audio?,
      # the "user's own custom upload" case the License note above refers
      # to). tile.current_audio_attachment resolves the tile's own override
      # first; only fall back to the image's shared audio when the tile has
      # none of its own, mirroring how #audio_url is populated for each case.
      attachment = tile.current_audio_attachment || tile.image&.current_audio_attachment
      return tile.to_obf_sound_format unless attachment

      # Read the real content_type off the resolved attachment's blob (which
      # may be the tile's own custom audio, not the shared Image's) and pass
      # it straight through — see the comment on BoardImage#to_obf_sound_format
      # for why re-deriving it independently there would be wrong.
      content_type = attachment.blob.content_type
      ext = attachment.blob.filename.extension.presence&.downcase || "mp3"
      # Keyed on the ATTACHMENT's id, not the tile's, so two tiles sharing the
      # same underlying audio attachment (e.g. both fall back to the same
      # Image's TTS audio) get the SAME zip path — matching how image_entry
      # keys both the path and the Asset id on doc.id. That agreement is what
      # lets ObzPackager#write_assets dedupe shared bytes by path; keying on
      # tile.id here (as before) produced two different paths for identical
      # bytes, defeating the dedupe and corrupting manifest["paths"]["sounds"]
      # (which is built as {attachment_id => path} and would silently drop
      # one of the two paths for the same id).
      path = "sounds/#{attachment.id}.#{ext}"

      if asset_mode == :inline
        # Sounds are small relative to images, so there is no separate inline
        # byte cap for them — but unlike images, inline audio bytes are NOT
        # currently counted against @inline_bytes_total / MAX_INLINE_BYTES;
        # that accumulator is only touched by attach_asset (images). This is
        # a known, accepted gap rather than an enforced limit.
        data = Base64.strict_encode64(attachment.download)
        return tile.to_obf_sound_format(mode: :inline, data: data, content_type: content_type)
      end

      assets << Asset.new(:sound, attachment.id.to_s, path, attachment)
      tile.to_obf_sound_format(mode: :package, path: path, content_type: content_type)
    rescue TooLarge
      raise
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] audio unreadable for board_image #{tile.id}: #{e.class}: #{e.message}"
      tile.to_obf_sound_format
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

    def record_license(verdict, tile)
      @evaluated_bundlable = true
      @owned_by_user ||= verdict.owned_by_user?
      @license_types << verdict.type if verdict.type.present?
      if verdict.attribution_required?
        @attribution << { board_image_id: tile.id, label: tile.label, license_type: verdict.type }
      end
    end

    # Any content the user owns makes the board theirs, not ours to license.
    # A board where nothing was ever positively evaluated as bundlable — every
    # asset skipped, or licensing never ran at all (asset_mode: :url) — has no
    # evidence to license openly on. Absence of evidence is not evidence of
    # openness: fail closed to "private", the same way
    # Images::RedistributionLicense fails closed per asset. Only declare the
    # open license when at least one non-user-owned asset was bundlable and
    # carried no more restrictive type.
    def derived_license
      return PRIVATE_LICENSE if @owned_by_user
      return PRIVATE_LICENSE unless @evaluated_bundlable
      return OPEN_LICENSE if @license_types.empty?

      { "type" => most_restrictive_type }
    end

    # The board must declare the MOST restrictive of the recognized types
    # present, not the alphabetically last one — "cc by-nc-sa" carries more
    # obligations than "public domain" and must not be dropped just because
    # "public domain" sorts later.
    def most_restrictive_type
      @license_types.uniq.max_by { |type| restrictiveness_score(type) }
    end

    def restrictiveness_score(type)
      score = 0
      score += 1 if type.include?("cc by")
      score += 2 if type.include?("-nc")
      score += 2 if type.include?("-nd")
      score += 1 if type.include?("-sa")
      score
    end
  end
end
