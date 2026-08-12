# Builds the HTML for a text tile and hands it to Chrome.
#
# Rendered at 2x the tile variant's 288px and downsampled by Active Storage's
# resize_to_limit, which is cheaper than asking Chrome for a device scale
# factor and gives the same antialiasing.
#
# Every value interpolated below comes from Images::TextTile::Options, which
# has already mapped client tokens onto server-owned CSS and escaped the text.
# Nothing here may take a raw param.
#
# The lines are emitted as separate <div>s rather than relying on CSS wrapping:
# the wrap points then match Options#lines exactly, which is what the frontend
# preview computes from the same algorithm. Letting the browser choose its own
# break points would put preview and render back out of sync.
module Images
  module TextTile
    class Renderer
      SIZE = 576

      def initialize(options)
        @options = options
      end

      def to_png
        HtmlToPng.call(
          html: html,
          width: SIZE,
          height: SIZE,
          scale: 1,
          transparent: @options.transparent?,
        )
      end

      def html
        <<~HTML
          <!DOCTYPE html>
          <html><head><meta charset="utf-8"><style>
            #{Fonts.face_css(@options.font)}
            html, body { margin: 0; padding: 0; width: #{SIZE}px; height: #{SIZE}px; }
            body { background: #{body_background}; }
            .tile {
              box-sizing: border-box;
              width: 100%; height: 100%;
              display: flex; flex-direction: column;
              align-items: #{flex_alignment}; justify-content: center;
              padding: #{(SIZE * Options::PADDING_RATIO).round(2)}px;
              font-family: '#{@options.css_family}', sans-serif;
              font-weight: #{@options.font_weight};
              font-style: #{@options.italic ? "italic" : "normal"};
              font-size: #{scaled_font_size}px;
              line-height: #{Options::LINE_HEIGHT};
              text-align: #{@options.align};
              text-transform: #{@options.css_text_transform};
              color: #{@options.text_color};
              overflow: hidden;
              word-break: break-word;
            }
          </style></head>
          <body><div class="tile">#{line_divs}</div></body></html>
        HTML
      end

      private

      # Options#font_size_px is in 300px-reference units (see REFERENCE_CANVAS);
      # this canvas is SIZE. Scaling here rather than in Options keeps the
      # fixture table shared with the TypeScript preview, which sizes its own
      # 288px box the same way.
      def scaled_font_size
        (@options.font_size_px * (SIZE / Options::REFERENCE_CANVAS)).round(2)
      end

      # omit_background only shows through where nothing is painted, so a
      # transparent tile must leave the body unset rather than paint "none".
      def body_background
        @options.transparent? ? "none" : @options.bg_color
      end

      def flex_alignment
        { "left" => "flex-start", "center" => "center", "right" => "flex-end" }.fetch(@options.align)
      end

      def line_divs
        @options.lines.map { |line| "<div>#{ERB::Util.html_escape(line)}</div>" }.join
      end
    end
  end
end
