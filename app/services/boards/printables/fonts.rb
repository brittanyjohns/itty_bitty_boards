# Nunito, base64-inlined into the printable layout's <style> block.
#
# The brand face is Nunito and the speakanyway-printables pipeline gets it by
# @importing Google Fonts at render time. We don't: a network fetch inside PDF
# generation is a flaky failure mode, and a font that fails to load fails
# *silently* — the page renders in the fallback and nobody notices until it's on
# Etsy. Vendoring the woff2 makes the render hermetic.
#
# Layouts must emit `face_css` with `<%==`, not `<%=`. It's a plain String, so
# `<%=` escapes 'Nunito' to &#39;Nunito&#39;, entities are never decoded inside
# <style>, and the @font-face is dropped — the same silent fallback as above.
# Pinned by spec/views/layouts/vendored_font_face_spec.rb.
#
# One file per subset, not per weight: Google serves Nunito as a variable font,
# so the same woff2 backs 400/600/800 and the @font-face just declares the whole
# axis. latin-ext is here so an accented board name doesn't fall back to the
# system stack mid-title.
#
# Files live in app/assets/fonts/nunito (read from disk, never served) under the
# SIL Open Font License 1.1 — OFL.txt ships beside them, as the license requires.
module Boards
  module Printables
    module Fonts
      DIR = Rails.root.join("app/assets/fonts/nunito").freeze

      SUBSETS = {
        # Basic Latin + Latin-1 Supplement, punctuation, currency.
        "nunito-latin.woff2" =>
          "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, " \
          "U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, " \
          "U+2212, U+2215, U+FEFF, U+FFFD",
        # Latin Extended-A/B and friends.
        "nunito-latin-ext.woff2" =>
          "U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, " \
          "U+0304, U+0308, U+0329, U+1D00-1DBF, U+1E00-1E9F, U+1EF2-1EFF, " \
          "U+2020, U+20A0-20AB, U+20AD-20C0, U+2113, U+2C60-2C7F, U+A720-A7FF",
      }.freeze

      # Caveat, the handwritten face the styled gallery slides use for their
      # corner accents ("Words within reach"). Same subsets and ranges as Nunito;
      # variable, so one file per subset carries 400-700.
      CAVEAT_DIR = Rails.root.join("app/assets/fonts/caveat").freeze
      CAVEAT_SUBSETS = {
        "caveat-latin.woff2" => SUBSETS.fetch("nunito-latin.woff2"),
        "caveat-latin-ext.woff2" => SUBSETS.fetch("nunito-latin-ext.woff2"),
      }.freeze

      # Memoized for the life of the process. RenderWrappers does four or five
      # renders per printable and a bundle regenerates often; re-reading and
      # re-encoding ~75 KB of woff2 every time is pure waste.
      def self.face_css
        @face_css ||= SUBSETS.map { |file, unicode_range| face(file, unicode_range) }.join("\n")
      end

      # Every face the styled gallery slides draw with: Nunito for body copy,
      # Fredoka for the rounded headlines (already vendored for text tiles — one
      # copy of the file, read through the module that owns it), Caveat for the
      # handwritten accents. Kept apart from #face_css so the print layouts don't
      # inline ~140 KB of faces they never use.
      def self.styled_face_css
        @styled_face_css ||= [
          face_css,
          Images::TextTile::Fonts.face_css("fredoka"),
          CAVEAT_SUBSETS.map do |file, unicode_range|
            face(file, unicode_range, family: "Caveat", dir: CAVEAT_DIR, weight: "400 700")
          end.join("\n"),
        ].join("\n")
      end

      def self.face(file, unicode_range, family: "Nunito", dir: DIR, weight: "200 1000")
        <<~CSS
          @font-face {
            font-family: '#{family}';
            font-style: normal;
            font-weight: #{weight};
            font-display: block;
            src: url(data:font/woff2;base64,#{encoded(dir, file)}) format('woff2');
            unicode-range: #{unicode_range};
          }
        CSS
      end
      private_class_method :face

      def self.encoded(dir, file)
        Base64.strict_encode64(dir.join(file).binread)
      end
      private_class_method :encoded
    end
  end
end
