require "rails_helper"

RSpec.describe Boards::BlueprintAssembler, type: :service do
  let(:user) { create(:user) }

  # The "home" template resolves every core label -> Image, raising if any is
  # missing, so seed images for the whole HOME tree before exercising it.
  def seed_template_images!
    labels = collect_labels(Boards::StarterBlueprints::HOME)
    labels.each { |label| create(:image, label: label, user_id: user.id) }
  end

  def collect_labels(tree)
    Array(tree[:tiles]).flat_map do |tile|
      [tile[:label]] + (tile[:children] ? collect_labels(tile[:children]) : [])
    end
  end

  describe "#call" do
    context "with a known template and interests" do
      before { seed_template_images! }

      # A top-level folder tile by label, and the labels inside its child board.
      def folder(blueprint, label)
        blueprint[:tiles].find { |t| t[:label] == label }
      end

      def folder_labels(blueprint, label)
        folder(blueprint, label)[:children][:tiles].map { |t| t[:label] }
      end

      it "gives every assembled tile a resolved integer image_id" do
        blueprint = described_class.new(
          template: "home", interests: ["apple", "trains", "grandma"], user: user,
        ).call

        expect(blueprint[:name]).to eq("Home")
        all_tiles(blueprint).each { |t| expect(t[:image_id]).to be_a(Integer) }
      end

      it "routes each interest into the matching category folder the template has" do
        blueprint = described_class.new(
          template: "home", interests: ["banana", "scared", "dinosaurs"], user: user,
        ).call

        expect(folder_labels(blueprint, "Food")).to include("banana")
        expect(folder_labels(blueprint, "Feelings")).to include("scared")
        expect(folder_labels(blueprint, "Play")).to include("dinosaurs")
        # Everything found a home — no catch-all folder appended.
        expect(blueprint[:tiles].map { |t| t[:label] }).not_to include("My Favorites")
      end

      it "puts interests with no matching folder in a 'My Favorites' catch-all" do
        blueprint = described_class.new(
          template: "home", interests: ["grandma", "minecraft"], user: user,
        ).call

        favorites = blueprint[:tiles].last
        expect(favorites[:label]).to eq("My Favorites")
        expect(favorites[:children][:name]).to eq("My Favorites")
        expect(favorites[:children][:tiles].map { |t| t[:label] }).to contain_exactly("grandma", "minecraft")
      end

      it "splits a mixed list between category folders and 'My Favorites'" do
        blueprint = described_class.new(
          template: "home", interests: ["apple", "grandma"], user: user,
        ).call

        expect(folder_labels(blueprint, "Food")).to include("apple")
        expect(folder_labels(blueprint, "My Favorites")).to eq(["grandma"])
      end

      it "dedupes an interest against a folder's existing seed tile" do
        # HOME's Food folder already seeds "apple"; routing it again must not dup.
        blueprint = described_class.new(template: "home", interests: ["apple"], user: user).call
        expect(folder_labels(blueprint, "Food").count("apple")).to eq(1)
      end

      it "leaves the curated core tiles untouched (interests never appear at top level)" do
        blueprint = described_class.new(
          template: "home", interests: ["apple", "grandma"], user: user,
        ).call

        top_labels = blueprint[:tiles].map { |t| t[:label] }
        expect(top_labels).to include("I", "want", "Food", "Feelings", "Play")
        expect(top_labels).not_to include("apple", "grandma")
      end
    end

    context "interest image resolution" do
      before { seed_template_images! }

      it "creates a new Image for an interest word that doesn't exist yet" do
        expect {
          described_class.new(template: "home", interests: ["dinosaurs"], user: user).call
        }.to change { Image.where(label: "dinosaurs").count }.from(0).to(1)
      end

      it "reuses an existing image instead of creating a duplicate" do
        create(:image, label: "trains", user_id: user.id)

        expect {
          described_class.new(template: "home", interests: ["trains"], user: user).call
        }.not_to change { Image.where(label: "trains").count }
      end
    end

    context "interest normalization" do
      before { seed_template_images! }

      it "trims, drops blanks, dedupes, lone-i -> I, and caps at MAX_INTERESTS" do
        raw = ["  trains ", "", "trains", "i"] + (1..20).map { |n| "word#{n}" }
        assembler = described_class.new(template: "home", interests: raw, user: user)

        expect(assembler.interests).to start_with("trains", "I")
        expect(assembler.interests.size).to eq(described_class::MAX_INTERESTS)
        expect(assembler.interests.count("trains")).to eq(1)
      end
    end

    context "with no interests" do
      before { seed_template_images! }

      it "builds the core template with no favorites folder" do
        blueprint = described_class.new(template: "home", interests: [], user: user).call
        expect(blueprint[:tiles].map { |t| t[:label] }).not_to include("My Favorites")
      end
    end

    context "with an unknown template" do
      it "raises UnknownTemplate" do
        expect {
          described_class.new(template: "not_a_template", user: user).call
        }.to raise_error(Boards::BlueprintAssembler::UnknownTemplate)
      end
    end
  end

  # Flatten every tile in a blueprint (depth-first) for assertions.
  def all_tiles(node)
    Array(node[:tiles]).flat_map do |tile|
      [tile] + (tile[:children] ? all_tiles(tile[:children]) : [])
    end
  end
end
