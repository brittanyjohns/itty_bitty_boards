require "rails_helper"

RSpec.describe CoachingPromptGenerator do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, parent_id: user.id, parent_type: "User") }

  describe ".for" do
    let!(:snack_set) do
      create(:coaching_prompt_set,
        slug: "snack_time_test",
        match_tags: %w[snack snack_time],
        published: true)
    end

    it "returns the curated set when one matches" do
      board.update!(tags: ["snack_time"])
      expect(described_class.for(board)).to eq(snack_set)
    end

    it "returns the cached AI-generated set when board.metadata points to one" do
      cached = create(:coaching_prompt_set,
        slug: "ai_cached_one",
        match_tags: [],
        source: "ai_generated")
      board.update!(tags: [], metadata: { "coaching_prompt_set_id" => cached.id })

      expect(described_class.for(board)).to eq(cached)
    end

    it "returns the seeded fallback set when staging is on" do
      board.update!(tags: ["unrelated"])
      allow(AppEnv).to receive(:staging?).and_return(true)
      fallback = create(:coaching_prompt_set,
        slug: CoachingPromptGenerator::FALLBACK_SLUG,
        published: false,
        match_tags: [])

      expect(described_class.for(board)).to eq(fallback)
    end

    it "calls OpenAI, persists, and caches when no curated match and not staging" do
      board.update!(tags: ["unknown_topic"])
      allow(AppEnv).to receive(:staging?).and_return(false)

      fake_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:chat).and_return(
        "choices" => [
          {
            "message" => {
              "content" => {
                "name" => "Made up",
                "description" => "desc",
                "strategies" => [
                  { "label" => "Offer a choice", "hint" => "Try two", "example_phrases" => ["A or B?"] },
                ],
              }.to_json,
            },
          },
        ],
      )

      expect {
        result = described_class.for(board)
        expect(result).to be_persisted
        expect(result.source).to eq("ai_generated")
        expect(result.strategies.first["label"]).to eq("Offer a choice")
      }.to change(CoachingPromptSet, :count).by(1)

      board.reload
      expect(board.metadata["coaching_prompt_set_id"]).to be_present

      # Second call must NOT hit OpenAI again — should return the cached set.
      expect(fake_client).not_to receive(:chat)
      result2 = described_class.for(board)
      expect(result2.id).to eq(board.metadata["coaching_prompt_set_id"])
    end

    it "returns the fallback when OpenAI raises an error" do
      board.update!(tags: ["unknown_topic"])
      allow(AppEnv).to receive(:staging?).and_return(false)
      fallback = create(:coaching_prompt_set,
        slug: CoachingPromptGenerator::FALLBACK_SLUG,
        published: false,
        match_tags: [])

      fake_client = instance_double(OpenAI::Client)
      allow(OpenAI::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:chat).and_raise(StandardError, "boom")

      expect(described_class.for(board)).to eq(fallback)
    end
  end
end
