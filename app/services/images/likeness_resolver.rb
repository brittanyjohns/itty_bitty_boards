module Images
  # Which communicator likeness, if any, a generation on this board should draw
  # its people with. The single answer every generation path asks.
  #
  # A board is ONE shared row that can sit on several dashboards, so "the
  # communicator" is only knowable when a caller names one or the board is on
  # exactly one of its owner's communicators. Anything else resolves to nil —
  # never a guess, because a guess draws one person's look onto someone else's
  # board.
  #
  # Resolution, in order:
  #   1. the board's own override — {"mode" => "none"} switches it off; a
  #      likeness hash wins outright
  #   2. an explicitly named communicator, only if the board's owner owns it
  #   3. the one communicator of the owner's that the board is attached to
  #
  # Menu boards never resolve: their tiles are food photos, not people.
  class LikenessResolver
    Result = Struct.new(:likeness, :age_band, keyword_init: true) do
      def fingerprint
        likeness.fingerprint
      end

      def prompt_clause
        likeness.prompt_clause(age_band: age_band)
      end

      # The look without its write-ins, for the refusal retry — nil when the
      # write-ins were the whole look, so the retry draws an ordinary picture
      # rather than stamping one with a look it didn't draw.
      def without_custom_extras
        stripped = likeness.without_custom_extras
        stripped.blank? ? nil : self.class.new(likeness: stripped, age_band: age_band)
      end

      # Whether this word's picture should look like the communicator at all.
      # The prompt, the doc stamp and reuse all ask this, per image, so they
      # can never disagree about one word.
      def applies_to?(image, user_input: nil)
        Images::LikenessApplicability.applies?(
          label: image.label, part_of_speech: image.part_of_speech, user_input: user_input,
        )
      end
    end

    def self.for(board:, communicator: nil)
      new(board, communicator).call
    end

    def initialize(board, communicator)
      @board = board
      @communicator = communicator
    end

    def call
      return nil unless @board.is_a?(Board)
      return nil if @board.is_a_menu?

      override = board_override
      return nil if override == :none

      communicator = owned_communicator
      likeness = override || communicator&.likeness
      return nil if likeness.nil? || likeness.blank?

      Result.new(likeness: likeness, age_band: communicator&.age_band)
    end

    private

    def board_override
      raw = @board.settings.is_a?(Hash) ? @board.settings["likeness"] : nil
      return nil unless raw.is_a?(Hash)
      return :none if raw["mode"].to_s == CommunicatorLikeness::NONE_MODE

      likeness = CommunicatorLikeness.from_hash(raw)
      likeness.present? ? likeness : nil
    end

    # A named communicator the owner doesn't own is refused, not swapped for an
    # attached one: the caller asked about a specific person.
    def owned_communicator
      return (owns?(@communicator) ? @communicator : nil) if @communicator

      candidates = @board.communicator_child_boards.map(&:child_account).compact.uniq.select { |account| owns?(account) }
      candidates.one? ? candidates.first : nil
    end

    def owns?(communicator)
      [communicator.user_id, communicator.owner_id].compact.include?(@board.user_id)
    end
  end
end
