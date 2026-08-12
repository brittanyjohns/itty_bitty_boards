# app/services/images/redistribution_license.rb
#
# May this doc's bytes be bundled into a user's export package?
#
# NOT the same question as Images::CommercialLicense, which asks whether
# SpeakAnyWay may SELL a product containing the image. Two deliberate
# differences:
#
#   * NC and ND licenses are fine here. NC forbids commercial use and ND
#     forbids derivatives; neither forbids redistribution. Excluding them
#     would drop perfectly exportable images from a personal export.
#   * A blank source_type is NOT disqualifying on its own. User uploads were
#     historically created without one (see Doc::SOURCE_TYPE_USER), so a
#     "nil is untrusted" rule would exclude a user's own photos from their own
#     export — the exact opposite of this feature's purpose.
#
# Ownership is checked BEFORE license: a user's own content is theirs and its
# license is not ours to evaluate. License rules gate only third-party content.
#
# The predicate FAILS CLOSED — anything unrecognized is not bundlable.
module Images
  module RedistributionLicense
    # License families that permit redistribution. Matched after the -sa/-nc/-nd
    # obligation suffixes are stripped, so "cc by-nc-sa 4.0" lands on "cc by".
    REDISTRIBUTABLE_FAMILIES = ["public domain", "cc0", "cc by"].freeze

    # We generated it; it's ours. Text tiles are rendered in-house from the
    # user's own words in an OFL font, so they belong here rather than in
    # USER_AUTHORED_SOURCE_TYPES — no user_id match should be required for a
    # teammate exporting a shared board.
    OWNED_SOURCE_TYPES = ["OpenAI", Doc::SOURCE_TYPE_TEXT_TILE].freeze

    # Scraped from the web: not the user's content, and carrying no license.
    UNTRUSTED_SOURCE_TYPES = ["GoogleSearch"].freeze

    # Source types that indicate a person uploaded the file through a
    # user-facing endpoint. nil/"" are here because uploads predating
    # Doc::SOURCE_TYPE_USER carry no source type.
    #
    # This list is what stops a stamped user_id from being mistaken for
    # authorship: Board.from_obf creates "ObfImport" docs with
    # `user_id: current_user.id`, so without this restriction an import of
    # someone else's proprietary symbols would re-export as the user's own.
    USER_AUTHORED_SOURCE_TYPES = [nil, "", Doc::SOURCE_TYPE_USER].freeze

    Result = Struct.new(:bundlable, :type, :attribution_required, :owned_by_user, :reason) do
      def bundlable? = !!bundlable

      def attribution_required? = !!attribution_required

      def owned_by_user? = !!owned_by_user
    end

    class << self
      def for(doc, exporting_user:)
        license = LicenseResolution.resolve(doc)

        if license == :protected
          return Result.new(false, nil, false, false, "proprietary symbol set")
        end

        if user_authored?(doc, exporting_user)
          return Result.new(true, nil, false, true, nil)
        end

        if OWNED_SOURCE_TYPES.include?(doc.source_type) || speakanyway_authored?(doc)
          return Result.new(true, nil, false, false, nil)
        end

        if UNTRUSTED_SOURCE_TYPES.include?(doc.source_type)
          return Result.new(false, nil, false, false, "web-sourced image with no license on record")
        end

        type = LicenseResolution.normalize_type(license.is_a?(Hash) ? license["type"] : license)

        if redistributable?(type)
          return Result.new(true, type, type.start_with?("cc by"), false, nil)
        end

        Result.new(false, type.presence, false, false, "no redistributable license on record")
      end

      private

      def user_authored?(doc, exporting_user)
        return false if exporting_user.nil?

        owned_by?(doc, exporting_user.id)
      end

      def speakanyway_authored?(doc)
        owned_by?(doc, User::DEFAULT_ADMIN_ID)
      end

      # An upload counts as owned only when the source type says a person
      # uploaded it AND the owner matches. Checking the parent Image as well as
      # the doc covers uploads created before the doc carried a user_id.
      def owned_by?(doc, owner_id)
        return false unless USER_AUTHORED_SOURCE_TYPES.include?(doc.source_type)
        return true if doc.user_id.present? && doc.user_id == owner_id

        parent = doc.documentable
        parent.is_a?(Image) && parent.user_id.present? && parent.user_id == owner_id
      end

      # Strip the obligation suffixes before matching so every CC BY variant
      # collapses onto the "cc by" family. "cc by-nc-sa 4.0" -> "cc by 4.0".
      def redistributable?(type)
        return false if type.blank?

        base = type.gsub(/-(sa|nc|nd)\b/, "").strip
        REDISTRIBUTABLE_FAMILIES.any? { |allowed| base == allowed || base.start_with?("#{allowed} ") }
      end
    end
  end
end
