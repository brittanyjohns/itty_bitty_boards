# The curated typefaces a text tile may be rendered in, base64-inlined into
# the render's <style> block.
#
# Vendored rather than @imported, for the reason Boards::Printables::Fonts
# documents: a network fetch inside a render is flaky, and a font that fails to
# load fails *silently* — the page renders in the fallback stack and nobody
# notices until it's on a printed board.
#
# NORMAL STYLE ONLY, deliberately. Italic is left to Chrome's synthetic
# oblique. The frontend preview requests the same axes from Google Fonts
# (src/data/text_tile.ts + the <link> in index.html), so both sides synthesize
# the same slant — shipping a true italic here and not there is exactly the
# preview-vs-result drift this whole approach exists to avoid.
#
# Two file shapes: variable families carry the whole weight axis in one file
# per subset; static families ship one file per weight per subset. `weights`
# says which, and `face_css` emits accordingly.
#
# latin-ext is carried for every family so an accented label (Spanish is a
# supported locale) doesn't fall back to the system stack mid-word.
#
# Files live under app/assets/fonts (read from disk, never served) under the
# SIL Open Font License 1.1 — OFL.txt ships beside each family, as required.
module Images
  module TextTile
    module Fonts
      Family = Struct.new(:key, :css_family, :dir, :weights, :variable, keyword_init: true)

      ROOT = Rails.root.join("app/assets/fonts").freeze

      # Basic Latin + Latin-1 Supplement, punctuation, currency.
      LATIN_RANGE =
        "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, " \
        "U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, " \
        "U+2212, U+2215, U+FEFF, U+FFFD".freeze

      # Latin Extended-A/B and friends.
      LATIN_EXT_RANGE =
        "U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, " \
        "U+0304, U+0308, U+0329, U+1D00-1DBF, U+1E00-1E9F, U+1EF2-1EFF, " \
        "U+2020, U+20A0-20AB, U+20AD-20C0, U+2113, U+2C60-2C7F, U+A720-A7FF".freeze

      SUBSETS = { "latin" => LATIN_RANGE, "latin-ext" => LATIN_EXT_RANGE }.freeze

      # Order is the order the picker shows them in. Atkinson leads because it
      # was drawn by the Braille Institute for low vision, which is the closest
      # fit to who reads an AAC tile.
      #
      # KEY LIST IS A CROSS-REPO CONTRACT with TEXT_TILE_FONTS in
      # itty-bitty-frontend/src/data/text_tile.ts. fonts_spec.rb asserts it;
      # so does text_tile.test.ts on the other side.
      FAMILIES = [
        Family.new(key: "atkinson", css_family: "Atkinson Hyperlegible",
                   dir: "text_tiles/atkinson", weights: [400, 700], variable: false),
        Family.new(key: "andika", css_family: "Andika",
                   dir: "text_tiles/andika", weights: [400, 700], variable: false),
        Family.new(key: "lexend", css_family: "Lexend",
                   dir: "text_tiles/lexend", weights: [100, 900], variable: true),
        Family.new(key: "nunito", css_family: "Nunito",
                   dir: "nunito", weights: [200, 1000], variable: true),
        Family.new(key: "fredoka", css_family: "Fredoka",
                   dir: "text_tiles/fredoka", weights: [300, 600], variable: true),
      ].freeze

      BY_KEY = FAMILIES.index_by(&:key).freeze
      KEYS = FAMILIES.map(&:key).freeze
      DEFAULT_KEY = "atkinson".freeze

      class << self
        def key?(key) = BY_KEY.key?(key)

        def fetch(key) = BY_KEY.fetch(key, BY_KEY.fetch(DEFAULT_KEY))

        # Only the requested family. Inlining all five would put ~400 KB of
        # base64 into every render for four faces nobody asked for.
        def face_css(key)
          family = fetch(key)
          (@face_css ||= {})[family.key] ||= build_face_css(family)
        end

        # Every woff2 this family declares, as repo-relative paths. Used by the
        # spec that asserts the files are actually on disk.
        def files_for(key)
          family = fetch(key)
          faces(family).map { |file, _weight| ROOT.join(family.dir, file) }
        end

        def license_path(key) = ROOT.join(fetch(key).dir, "OFL.txt")

        private

        def build_face_css(family)
          faces(family).map { |file, weight| face(family, file, weight) }.join("\n")
        end

        # [[filename, font-weight value], ...]
        def faces(family)
          SUBSETS.keys.flat_map do |subset|
            if family.variable
              [["#{family.key}-#{subset}.woff2", "#{family.weights.first} #{family.weights.last}"]]
            else
              family.weights.map { |w| ["#{family.key}-#{w}-#{subset}.woff2", w.to_s] }
            end
          end
        end

        def face(family, file, weight)
          subset = file.include?("latin-ext") ? "latin-ext" : "latin"
          <<~CSS
            @font-face {
              font-family: '#{family.css_family}';
              font-style: normal;
              font-weight: #{weight};
              font-display: block;
              src: url(data:font/woff2;base64,#{encoded(family, file)}) format('woff2');
              unicode-range: #{SUBSETS.fetch(subset)};
            }
          CSS
        end

        def encoded(family, file)
          Base64.strict_encode64(ROOT.join(family.dir, file).binread)
        end
      end
    end
  end
end
