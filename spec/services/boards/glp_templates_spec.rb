require "rails_helper"

RSpec.describe Boards::GlpTemplates do
  let(:admin) { create(:admin_user) }

  describe ".seed!" do
    it "creates the six GLP template boards with the expected metadata" do
      boards = described_class.seed!(admin: admin)

      expect(boards.size).to eq(6)
      boards.each do |board|
        expect(board).to be_persisted
        expect(board.is_template).to be(true)
        expect(board.predefined).to be(true)
        expect(board.category).to eq("glp")
        expect(board.board_type).to eq("glp_template")
        expect(board.user_id).to eq(admin.id)
        expect(board.tags).to include("glp")
        expect(board.board_images.count).to be > 0
      end
    end

    it "tags each board with its stages and communicative function" do
      described_class.seed!(admin: admin)
      greetings = Board.find_by(slug: "glp-greetings-social")

      expect(greetings.tags).to include("glp", "stage_1", "stage_2", "communicative_function:greetings")
    end

    it "marks tiles as whole-phrase (part_of_speech: phrase)" do
      described_class.seed!(admin: admin)
      greetings = Board.find_by(slug: "glp-greetings-social")

      phrase_images = greetings.board_images.map(&:image)
      expect(phrase_images.map(&:part_of_speech).uniq).to eq(["phrase"])
      expect(greetings.board_images.map(&:label)).to include("hi there!")
    end

    it "is idempotent — re-running creates no duplicate boards or tiles" do
      described_class.seed!(admin: admin)
      first_counts = Board.where(category: "glp").order(:slug).map { |b| [b.slug, b.board_images.count] }

      described_class.seed!(admin: admin)
      second_counts = Board.where(category: "glp").order(:slug).map { |b| [b.slug, b.board_images.count] }

      expect(Board.where(category: "glp").count).to eq(6)
      expect(second_counts).to eq(first_counts)
    end

    it "raises a clear error when no admin is available" do
      expect { described_class.seed!(admin: nil) }
        .to raise_error(/No admin user available/)
    end
  end

  describe ".catalog" do
    it "returns one entry per seeded board with key/name/kind/tiles" do
      described_class.seed!(admin: admin)
      catalog = described_class.catalog

      expect(catalog.size).to eq(6)
      entry = catalog.find { |c| c[:key] == "glp-greetings-social" }
      expect(entry[:kind]).to eq("glp")
      expect(entry[:category]).to eq("glp")
      expect(entry[:name]).to eq("Greetings & Social")
      expect(entry[:tiles]).to include("hi there!")
    end

    it "is empty when no GLP boards are seeded" do
      expect(described_class.catalog).to eq([])
    end
  end

  describe ".recommended_for" do
    it "returns a stage-appropriate template slug" do
      expect(described_class.recommended_for(1)).to eq("glp-greetings-social")
      expect(described_class.recommended_for(3)).to eq("glp-comments-observations")
    end

    it "coerces a string stage" do
      expect(described_class.recommended_for("2")).to eq("glp-greetings-social")
    end

    it "returns nil for a blank stage" do
      expect(described_class.recommended_for(nil)).to be_nil
      expect(described_class.recommended_for("")).to be_nil
    end
  end
end
