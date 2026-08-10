module Boards
  module AdminBuilder
    # Page keys are the link targets a tile points at with `>key`, so every
    # producer of one — the AI drafters and the admin's own typing — has to
    # slugify it the same way or a link silently resolves to nothing.
    module Keys
      module_function

      # Strips leading/trailing underscores from a slugified key — except when
      # the value already equals the root sentinel, which is nothing but
      # underscores and would otherwise be stripped to blank.
      def normalize(value)
        cleaned = value.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_")
        return cleaned if cleaned == Plan::ROOT_KEY

        cleaned.gsub(/\A_+|_+\z/, "")
      end
    end
  end
end
