require "rails_helper"

# The anonymous / guest generated-board path (POST /api/generated_boards and
# POST /api/internal/generated_boards both enqueue this job).
#
# #911: the job used to hand-roll a prompt and call
# Board#get_word_suggestions_from_prompt, which runs under the incremental
# "add words" system prompt and never reaches Prompts::Aac.with_core_floor.
# A guest "snack time" board came back as twelve foods with no way to refuse.
# These specs lock the whole-board path — and therefore the core floor — in.
RSpec.describe GenerateFreeBoardJob, type: :job do
  # Both callers (the anonymous funnel and the internal endpoint) enqueue this
  # same job with the same four arguments; the board's ownership makes no
  # difference to the word-generation path under test.
  let(:board) do
    create(
      :board,
      name: "Snack Time",
      board_type: "generated",
      large_screen_columns: 4,
      medium_screen_columns: 4,
      small_screen_columns: 2,
      status: "generating",
    )
  end

  let(:word_count) { 12 }
  let(:food_nouns) do
    %w[apple banana cracker cheese yogurt grapes pretzel cookie juice milk carrot sandwich]
  end

  # Captured word list the job hands to image creation — the list that becomes
  # the board's tiles.
  let(:captured_words) { [] }

  before do
    allow(Board).to receive(:find_by).with(id: board.id).and_return(board)
    allow(board).to receive(:find_or_create_images_from_word_list) { |words| captured_words.replace(Array(words)) }
    allow(board).to receive(:reset_layouts)
    allow(board).to receive(:generate_previews)
    # Avoid the literal 2-second sleep in the job.
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  # Stubs the OpenAI call itself rather than the Board method, so the real
  # Board#get_words_for_scenario -> Prompts::Aac.with_core_floor path runs.
  def stub_ai_words(words)
    client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(client)
    allow(client).to receive(:get_word_suggestions_from_prompt)
      .and_return(words.nil? ? { content: nil } : { content: { "words" => words }.to_json })
    client
  end

  describe "core floor on a nouns-only AI response" do
    before { stub_ai_words(food_nouns) }

    it "adds the missing CORE_STARTER_WORDS without growing the board" do
      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      expect(captured_words.size).to eq(word_count)
      Prompts::Aac::CORE_STARTER_WORDS.each do |core|
        expect(captured_words.map(&:downcase)).to include(core.downcase)
      end
    end

    it "spends at most word_count / 2 cells on the floor" do
      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      injected = captured_words.map(&:downcase) & Prompts::Aac::CORE_STARTER_WORDS.map(&:downcase)
      expect(injected.size).to be <= (word_count / 2)
      # The topic survives: the model's highest-ranked words keep their cells.
      expect(captured_words.map(&:downcase) & food_nouns).not_to be_empty
    end

    it "marks the board complete" do
      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      expect(board.reload.status).to eq("complete")
    end
  end

  describe "when the AI response already carries some core words" do
    let(:mixed_words) do
      %w[no more apple banana cracker cheese yogurt grapes pretzel cookie juice milk]
    end

    before { stub_ai_words(mixed_words) }

    it "does not duplicate them" do
      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      labels = captured_words.map(&:downcase)
      expect(labels.count("no")).to eq(1)
      expect(labels.count("more")).to eq(1)
      expect(labels.size).to eq(word_count)
      expect(labels.uniq.size).to eq(labels.size)
    end
  end

  describe "when the AI returns nothing" do
    before { stub_ai_words(nil) }

    it "stays a failure rather than shipping a core-only board" do
      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      expect(board).not_to have_received(:find_or_create_images_from_word_list)
      expect(captured_words).to be_empty
      expect(board.reload.status).not_to eq("complete")
    end
  end

  describe "prompt path" do
    it "uses the whole-board method, not the incremental prompt helper" do
      stub_ai_words(food_nouns)
      expect(board).to receive(:get_words_for_scenario)
        .with("snack time", "5-9", word_count).and_call_original

      described_class.new.perform(board.id, "snack time", "5-9", word_count)

      # The real guard against #911: a hand-rolled prompt calling
      # #get_word_suggestions_from_prompt directly never reaches
      # Prompts::Aac.with_core_floor, so the core words could not appear in a
      # nouns-only AI response. Their presence proves the whole-board path ran.
      expect(captured_words.map(&:downcase))
        .to include(*Prompts::Aac::CORE_STARTER_WORDS.map(&:downcase))
    end
  end
end
