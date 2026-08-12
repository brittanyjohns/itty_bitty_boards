# The single trust boundary for a text tile render.
#
# NO RAW CSS FROM THE CLIENT EVER REACHES THE RENDERED HTML. The client sends
# tokens ("m", "upper", "center") and a font *key*; this object maps them to
# server-owned CSS values. Colors are matched against a hex pattern and
# discarded if they don't fit. The text itself is escaped and length-capped —
# it is the one client string that lands in the document, and Chrome will
# happily execute whatever is in there.
#
# Unknown values fall back to the default rather than raising: a stale client
# or a hand-edited jsonb blob should render something sane, not 500. `valid?`
# is reserved for input we want to reject loudly (currently just a font key
# that doesn't exist, which is a client bug worth surfacing).
#
# to_h returns only normalized, whitelisted values, so what we persist in
# board_images.data["text_image"] is already safe to feed straight back into
# from_params when the editor reopens.
module Images
  module TextTile
    class Options
      MAX_TEXT_LENGTH = 60

      HEX_COLOR = /\A#(\h{3}|\h{6})\z/
      TRANSPARENT = "transparent".freeze

      DEFAULT_TEXT_COLOR = "#1f1b2e".freeze
      DEFAULT_BG_COLOR = "#ffffff".freeze

      # Multipliers on the auto-fitted size, never absolute pixels — a long
      # label on "xl" must still fit the tile.
      SIZES = { "s" => 0.75, "m" => 1.0, "l" => 1.25, "xl" => 1.5 }.freeze
      DEFAULT_SIZE = "m".freeze

      CASES = {
        "none" => "none",
        "upper" => "uppercase",
        "lower" => "lowercase",
        "title" => "capitalize",
      }.freeze
      DEFAULT_CASE = "none".freeze

      ALIGNS = %w[left center right].freeze
      DEFAULT_ALIGN = "center".freeze

      # Mirrors BoardsHelper#generate_placeholder_image and its TypeScript twin
      # computeTextTileLayout (itty-bitty-frontend/src/data/text_tile.ts).
      # All three must agree or the preview lies about the result.
      #
      # Latin-centric by construction: "characters per line" is meaningless for
      # CJK and wrong for RTL. Revisit with board_image.language rather than
      # tuning these numbers.
      MAX_CHARS_PER_LINE = 10
      MAX_LINES = 3
      MIN_FONT_SIZE = 24.0
      # Higher than the placeholder helper's 80. There, a big glyph is an
      # accident of a missing picture; here the user chose text as the picture,
      # so a one- or two-character tile ("+", "?", "A") should fill it. The
      # height cap below still governs anything that wraps.
      MAX_FONT_SIZE = 140.0
      # Average glyph advance, in em, used to guess how wide a line will be.
      # The placeholder helper's equivalent constant assumed ~0.46em against the
      # FULL canvas width, which overflows once the size cap stops hiding it —
      # "ALL DONE" was computed as one line and rendered as two, rescued only by
      # word-break. Measured across the five families, 0.62 is safe for bold,
      # and uppercase runs wider still.
      CHAR_WIDTH_EM = 0.62
      UPPERCASE_WIDTH_FACTOR = 1.12

      # font_size_px is expressed against a 300px-square tile, the space the
      # placeholder SVG was drawn in. Callers rendering at another size scale
      # by their own canvas / REFERENCE_CANVAS — the numbers stay comparable
      # across Ruby, the TypeScript twin, and the 576px render, which is what
      # lets one fixture table test all three.
      REFERENCE_CANVAS = 300.0

      # Both the height cap below and the renderer's CSS read these, so a
      # change to the leading or the inset can't drift out of the cap that
      # assumes it.
      LINE_HEIGHT = 1.12
      PADDING_RATIO = 1 / 12.0

      attr_reader :text, :font, :text_color, :bg_color, :size, :bold, :italic,
                  :text_case, :align, :hide_label, :errors

      def self.from_params(params)
        new(
          text: params[:text],
          font: params[:font],
          text_color: params[:text_color],
          bg_color: params[:bg_color],
          size: params[:size],
          bold: params[:bold],
          italic: params[:italic],
          text_case: params[:case] || params[:text_case],
          align: params[:align],
          hide_label: params[:hide_label],
        )
      end

      def initialize(text:, font: nil, text_color: nil, bg_color: nil, size: nil,
                     bold: nil, italic: nil, text_case: nil, align: nil, hide_label: nil)
        @errors = []

        @text = normalize_text(text)
        @font = normalize_font(font)
        @text_color = normalize_color(text_color, DEFAULT_TEXT_COLOR)
        @bg_color = normalize_color(bg_color, DEFAULT_BG_COLOR, allow_transparent: true)
        @size = SIZES.key?(size.to_s) ? size.to_s : DEFAULT_SIZE
        @bold = truthy?(bold)
        @italic = truthy?(italic)
        @text_case = CASES.key?(text_case.to_s) ? text_case.to_s : DEFAULT_CASE
        @align = ALIGNS.include?(align.to_s) ? align.to_s : DEFAULT_ALIGN
        @hide_label = hide_label.nil? ? true : truthy?(hide_label)
      end

      def valid? = errors.empty? && text.present?

      def transparent? = bg_color == TRANSPARENT

      def family = Fonts.fetch(font)

      def css_family = family.css_family

      def font_weight = bold ? 700 : 400

      def css_text_transform = CASES.fetch(text_case)

      # What the tile actually reads as — the wrapped/ellipsized lines with the
      # case transform applied in Ruby. CSS `text-transform` is what paints it,
      # but alt text and specs need the same string without a browser, and it
      # has to agree with #lines rather than with the raw input (a label long
      # enough to be truncated shows "and then...", not the whole sentence).
      def display_text
        apply_case(lines.join(" "))
      end

      # Wrapped lines, at most MAX_LINES, last one ellipsized when it overflows.
      def lines
        key = text.presence || "..."
        wrapped = []
        current = ""

        key.split(/\s+/).each do |word|
          candidate = current.present? ? "#{current} #{word}" : word
          if candidate.length <= MAX_CHARS_PER_LINE
            current = candidate
          else
            wrapped << current if current.present?
            current = word
          end
        end
        wrapped << current if current.present?
        wrapped = [key] if wrapped.empty?

        final = wrapped.first(MAX_LINES)
        final[MAX_LINES - 1] = "#{final[MAX_LINES - 1]}..." if wrapped.length > MAX_LINES
        final
      end

      # Auto-fit against the longest line, then scale by the user's size
      # choice. In REFERENCE_CANVAS units — see that constant.
      def font_size_px
        wrapped = lines
        longest = wrapped.map(&:length).max || 1

        # Fit inside the PADDED box, not the whole canvas — the text is inset.
        inset = REFERENCE_CANVAS * PADDING_RATIO * 2
        available = REFERENCE_CANVAS - inset

        char_em = CHAR_WIDTH_EM
        char_em *= UPPERCASE_WIDTH_FACTOR if text_case == "upper"
        by_width = available / (longest * char_em)

        # The width fit alone doesn't know how many lines it produced, so three
        # short lines at the max size overflow the tile vertically — visible as
        # clipped descenders on a wrapped phrase like "I want more please".
        by_height = available / (wrapped.size * LINE_HEIGHT)

        base = [[[by_width, by_height].min, MAX_FONT_SIZE].min, MIN_FONT_SIZE].max
        (base * SIZES.fetch(size)).round(2)
      end

      def to_h
        {
          "text" => text,
          "font" => font,
          "text_color" => text_color,
          "bg_color" => bg_color,
          "size" => size,
          "bold" => bold,
          "italic" => italic,
          "case" => text_case,
          "align" => align,
          "hide_label" => hide_label,
        }
      end

      # Identity of the rendered output — everything that changes the pixels,
      # and nothing that doesn't (hide_label is a tile setting, not paint).
      # The controller compares this against the stored config to skip a
      # redundant Chrome fork.
      def render_digest
        Digest::SHA256.hexdigest(to_h.except("hide_label").sort.to_s)
      end

      private

      def apply_case(value)
        case text_case
        when "upper" then value.upcase
        when "lower" then value.downcase
        when "title" then value.split(/(\s+)/).map { |part| part.match?(/\s/) ? part : part.capitalize }.join
        else value
        end
      end

      def normalize_text(value)
        value.to_s.strip.slice(0, MAX_TEXT_LENGTH).to_s
      end

      def normalize_font(value)
        key = value.to_s
        return Fonts::DEFAULT_KEY if key.blank?

        unless Fonts.key?(key)
          errors << "unknown_font"
          return Fonts::DEFAULT_KEY
        end
        key
      end

      def normalize_color(value, fallback, allow_transparent: false)
        candidate = value.to_s.strip.downcase
        return TRANSPARENT if allow_transparent && candidate == TRANSPARENT
        return candidate if candidate.match?(HEX_COLOR)

        fallback
      end

      def truthy?(value)
        [true, "true", "1", 1].include?(value)
      end
    end
  end
end
