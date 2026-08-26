# Collapses byte-identical image XObjects in a merged printable down to one
# copy each.
#
# Every board page is its own Grover render, so art that repeats across pages
# is embedded once PER PAGE: the logo band in the header, and the nav-row tiles
# `Boards::NavRowSync` reproduces on every page of a set.
#
# CombinePDF already collapses objects its own `==` calls equal, and that is
# why this looks unnecessary until you measure it: an image dict carrying an
# indirect reference compares unequal even when the target bytes match, so
# every tile with an `/SMask` — which is all transparent tile art — survives
# as its own object. A ten-board set's colour file was 17.1 MB holding 7.8 MB
# of byte-identical image streams.
#
# Pointing each page's resource entry at ONE Ruby object per distinct picture
# is all it takes: CombinePDF then assigns that object a single id and writes
# its bytes once. Page content streams are untouched, so this is invisible in
# the printed result — it is the same picture, named once. 17.1 MB -> 9.2 MB
# on that set, same 14 pages, same pixels.
module Boards
  module Printables
    class DedupeImages
      # The image attributes that make two streams the same picture. Compared
      # explicitly rather than by inspecting the whole dict: `SMask` and
      # `ColorSpace` are references, and CombinePDF inlines the entire
      # referenced object into them.
      IDENTITY_KEYS = %i[
        Width Height BitsPerComponent ColorSpace Filter DecodeParms Decode
        ImageMask Interpolate
      ].freeze

      Result = Struct.new(:deduped, :unique, keyword_init: true)

      def initialize(pdf)
        @pdf = pdf
        @canonical = {}
        @visited_forms = Set.new
        @deduped = 0
      end

      def call
        pdf.pages.each { |page| dedupe_resources(page[:Resources]) }
        Result.new(deduped: deduped, unique: canonical.size)
      end

      private

      attr_reader :pdf, :canonical, :visited_forms, :deduped

      # Page resources arrive either as a plain dict or as a reference hash
      # carrying the real object, depending on how Chrome wrote the source.
      def deref(object)
        object.is_a?(Hash) ? (object[:referenced_object] || object) : object
      end

      def dedupe_resources(resources)
        resources = deref(resources)
        return unless resources.is_a?(Hash)

        xobjects = deref(resources[:XObject])
        return unless xobjects.is_a?(Hash)

        xobjects.each do |name, reference|
          object = deref(reference)
          next unless object.is_a?(Hash)

          case object[:Subtype]
          when :Image then canonicalize(xobjects, name, reference, object)
          when :Form then descend_into_form(object)
          end
        end
      end

      # A Form XObject carries its own resources, so an image can sit a level
      # down. Guarded by a visited set: a form shared by several pages is one
      # object, and re-walking it would be wasted work at best.
      def descend_into_form(form)
        return unless visited_forms.add?(form.object_id)

        dedupe_resources(form[:Resources])
      end

      def canonicalize(xobjects, name, reference, object)
        return unless object[:raw_stream_content]

        first = canonical[fingerprint(object)] ||= reference
        # Compare the IMAGE, not the reference hash wrapping it. CombinePDF
        # already collapses objects its own equality check calls equal, and
        # those arrive as two wrappers around one object — swapping them is a
        # no-op that would inflate the count without freeing a byte.
        return if deref(first).equal?(object)

        xobjects[name] = first
        @deduped += 1
      end

      # Tile art is transparent PNG, so Chrome emits an `/SMask` alongside most
      # images. The mask has to be part of the fingerprint — without it two
      # pictures with identical colour data and different alpha would collapse
      # into one, and the wrong one would print.
      def fingerprint(object)
        digest = Digest::SHA256.new
        IDENTITY_KEYS.each { |key| digest << "#{key}=#{deref(object[key]).inspect};" }
        digest << "smask=#{smask_digest(object)};"
        digest << object[:raw_stream_content].to_s
        digest.hexdigest
      end

      def smask_digest(object)
        smask = deref(object[:SMask])
        return "none" unless smask.is_a?(Hash) && smask[:raw_stream_content]

        Digest::SHA256.hexdigest(smask[:raw_stream_content])
      end
    end
  end
end
