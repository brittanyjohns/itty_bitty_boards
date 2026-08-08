module Boards
  module AdminBuilder
    # The builder's textarea format, both directions.
    #
    # One tile per line: `word`, `word | part_of_speech`,
    # `word | part_of_speech | tile text`, and a field beginning with `>` names
    # the page the tile opens — wherever in the line it appears, so
    # `Food | noun | >food` doesn't force an empty tile-text field just to reach
    # a fourth position.
    #
    # Parsing and rendering live together because `.render` has to be the exact
    # inverse of `.parse`: the AI set drafter emits link tokens, and duplicating
    # a past build back into the form round-trips a stored plan through both.
    #
    # Known limit of the format, not of this code: tile text that itself starts
    # with `>` parses back as a link. Not worth escaping — no AAC tile reads
    # that way.
    module WordList
      LINK_TOKEN = ">".freeze

      module_function

      def parse(text)
        text.to_s.split("\n").filter_map do |line|
          line = line.strip
          next if line.blank?

          label, *rest = line.split("|").map { |part| part.to_s.strip }
          links_to = rest.find { |field| field.start_with?(LINK_TOKEN) }
          part_of_speech, display_label = rest - [links_to].compact

          {
            label: label.to_s,
            part_of_speech: part_of_speech.presence || "default",
            display_label: display_label.presence,
            links_to: links_to&.delete_prefix(LINK_TOKEN)&.strip&.downcase.presence,
          }.compact
        end
      end

      def render(tiles)
        Array(tiles).map { |tile| render_tile(tile) }.join("\n")
      end

      # The part of speech is always emitted, even when it's "default" — the
      # line round-trips either way, and a uniform shape reads better in a
      # textarea of 84 lines than a ragged one.
      def render_tile(tile)
        tile = tile.symbolize_keys
        fields = [tile[:label].to_s, tile[:part_of_speech].presence || "default"]
        fields << tile[:display_label].to_s if tile[:display_label].present?
        fields << "#{LINK_TOKEN}#{tile[:links_to]}" if tile[:links_to].present?
        fields.join(" | ")
      end
    end
  end
end
