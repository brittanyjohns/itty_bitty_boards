# Nunito, base64-inlined into the printable layout's <style> block.
#
# The brand face is Nunito and the speakanyway-printables pipeline gets it by
# @importing Google Fonts at render time. We don't: a network fetch inside PDF
# generation is a flaky failure mode, and a font that fails to load fails
# *silently* — the page renders in the fallback and nobody notices until it's on
# Etsy. Vendoring the woff2 makes the render hermetic.
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

      # Memoized for the life of the process. RenderWrappers does four or five
      # renders per printable and a bundle regenerates often; re-reading and
      # re-encoding ~75 KB of woff2 every time is pure waste.
      def self.face_css
        @face_css ||= SUBSETS.map { |file, unicode_range| face(file, unicode_range) }.join("\n")
      end

      def self.face(file, unicode_range)
        <<~CSS
          @font-face {
            font-family: 'Nunito';
            font-style: normal;
            font-weight: 200 1000;
            font-display: block;
            src: url(data:font/woff2;base64,#{encoded(file)}) format('woff2');
            unicode-range: #{unicode_range};
          }
        CSS
      end
      private_class_method :face

      def self.encoded(file)
        Base64.strict_encode64(DIR.join(file).binread)
      end
      private_class_method :encoded
    end
  end
end
