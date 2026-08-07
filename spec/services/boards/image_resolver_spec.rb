require "rails_helper"

RSpec.describe Boards::ImageResolver do
  let(:owner) { create(:user) }
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def with_art(image, count: 1)
    count.times { create(:doc, documentable: image, user: image.user || admin) }
    image
  end

  # #574: resolving a label at a time cost 2-3 queries per tile, which is most
  # of what pushed a 48-cell bulk request toward the timeout that made the
  # endpoint 500 after committing.
  describe ".resolve_all" do
    it "picks the same image per label as .resolve does" do
      create(:image, label: "animals", user_id: admin.id)
      animals = with_art(create(:image, label: "animals", user_id: admin.id))
      few = with_art(create(:image, label: "ball", user_id: admin.id), count: 1)
      many = with_art(create(:image, label: "ball", user_id: admin.id), count: 3)
      owner_art = with_art(create(:image, label: "dog", user_id: owner.id))

      resolved = described_class.resolve_all(["Animals", "ball", "dog"], owner: owner)

      expect(resolved["animals"]).to eq(animals)
      expect(resolved["ball"]).to eq(many)
      expect(resolved["ball"]).not_to eq(few)
      expect(resolved["dog"]).to eq(owner_art)
      %w[Animals ball dog].each do |label|
        expect(resolved[described_class.normalize(label)]).to eq(described_class.resolve(label, owner: owner))
      end
    end

    it "keys on the normalized label so any casing looks the same up" do
      arted = with_art(create(:image, label: "stop", user_id: admin.id))

      resolved = described_class.resolve_all(["Stop", "STOP", "stop"], owner: owner)

      expect(resolved.keys).to eq(["stop"])
      expect(resolved["stop"]).to eq(arted)
    end

    it "falls back to an existing blank image, and creates one only when nothing matches" do
      blank = create(:image, label: "zzz_niche", user_id: admin.id)

      resolved = nil
      expect {
        resolved = described_class.resolve_all(["zzz_niche", "brand_new_batch_word"], owner: owner)
      }.to change(Image, :count).by(1)

      expect(resolved["zzz_niche"]).to eq(blank)
      expect(resolved["brand_new_batch_word"].label).to eq("brand_new_batch_word")
    end

    it "keeps the authored casing on an image it has to create" do
      resolved = described_class.resolve_all(["BrandNewCased"], owner: owner)

      # The authored casing now lives on display_label; label is the lowercase
      # matching key, so the next resolve for "brandnewcased" finds this row
      # instead of creating a second one.
      expect(resolved["brandnewcased"].display_label).to eq("BrandNewCased")
      expect(resolved["brandnewcased"].label).to eq("brandnewcased")
    end

    it "does not scale its query count with the number of labels" do
      def query_count_for(n, owner, admin)
        labels = n.times.map { |i| "batchword#{n}x#{i}" }
        labels.each { |label| create(:doc, documentable: create(:image, label: label, user_id: admin.id), user: admin) }

        queries = 0
        callback = lambda do |_name, _start, _finish, _id, payload|
          next if payload[:sql].to_s.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

          queries += 1
        end

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          expect(described_class.resolve_all(labels, owner: owner).size).to eq(n)
        end
        queries
      end

      # Flat: the art lookup is two queries (owner scope, then public scope)
      # however many labels are asked for — not 2-3 per label as `resolve` is.
      expect(query_count_for(12, owner, admin)).to eq(query_count_for(3, owner, admin))
    end

    it "returns an empty hash for no labels" do
      expect(described_class.resolve_all([], owner: owner)).to eq({})
      expect(described_class.resolve_all([" ", nil], owner: owner)).to eq({})
    end
  end

  describe ".resolve" do
    it "prefers a public/admin image that has art over a blank same-label image" do
      blank = create(:image, label: "animals", user_id: admin.id)         # lower id, no art
      arted = with_art(create(:image, label: "animals", user_id: admin.id)) # higher id, has art

      result = described_class.resolve("Animals", owner: owner)

      expect(result).to eq(arted)
      expect(result).not_to eq(blank)
    end

    it "prefers the owner's own art-bearing image over a public one" do
      with_art(create(:image, label: "dog", user_id: admin.id))
      owner_art = with_art(create(:image, label: "dog", user_id: owner.id))

      expect(described_class.resolve("dog", owner: owner)).to eq(owner_art)
    end

    it "falls back to an existing blank image when no art exists for the label" do
      blank = create(:image, label: "zzz_niche", user_id: admin.id)

      expect(described_class.resolve("zzz_niche", owner: owner)).to eq(blank)
    end

    it "creates an owner-owned blank image when none exists for the label" do
      expect {
        result = described_class.resolve("brand_new_word", owner: owner)
        expect(result.label).to eq("brand_new_word")
        expect(result.user_id).to eq(owner.id)
      }.to change(Image, :count).by(1)
    end

    it "normalizes the label before resolving" do
      arted = with_art(create(:image, label: "feelings", user_id: admin.id))
      expect(described_class.resolve("Feelings", owner: owner)).to eq(arted)
    end

    it "prefers the admin 'default' image with the MOST docs over a thinner one" do
      few  = with_art(create(:image, label: "ball", user_id: admin.id), count: 1)
      many = with_art(create(:image, label: "ball", user_id: admin.id), count: 3)

      result = described_class.resolve("ball", owner: owner)

      expect(result).to eq(many)
      expect(result).not_to eq(few)
    end
  end

  describe ".best_arted_for" do
    it "returns nil and creates nothing when no art exists for the label" do
      create(:image, label: "no_art_here", user_id: admin.id)

      expect {
        expect(described_class.best_arted_for("No_Art_Here", owner)).to be_nil
      }.not_to change(Image, :count)
    end
  end

  describe ".upgrade_board_tiles!" do
    let(:board) { create(:board, user: owner) }

    it "re-points a blank tile to the curated art image for its label, keeping the authored label" do
      blank = create(:image, label: "animals", user_id: admin.id)
      arted = with_art(create(:image, label: "animals", user_id: admin.id))
      tile  = board.add_image(blank.id)
      tile.update_columns(label: "Animals", display_label: "Animals")

      described_class.upgrade_board_tiles!(board, owner: owner)

      tile.reload
      expect(tile.image_id).to eq(arted.id)
      expect(tile.label).to eq("Animals")
      expect(tile.display_label).to eq("Animals")
    end

    it "leaves a tile that already has art untouched" do
      arted = with_art(create(:image, label: "dog", user_id: admin.id))
      other = with_art(create(:image, label: "dog", user_id: admin.id), count: 5)
      tile  = board.add_image(arted.id)

      described_class.upgrade_board_tiles!(board, owner: owner)

      expect(tile.reload.image_id).to eq(arted.id)
      expect(tile.image_id).not_to eq(other.id)
    end

    it "leaves a blank tile blank when no art exists for the label" do
      blank = create(:image, label: "niche_word", user_id: admin.id)
      tile  = board.add_image(blank.id)

      expect {
        described_class.upgrade_board_tiles!(board, owner: owner)
      }.not_to change(Image, :count)
      expect(tile.reload.image_id).to eq(blank.id)
    end
  end

  describe ".art?" do
    it "is true when the image has a doc" do
      expect(described_class.art?(with_art(create(:image, user_id: admin.id)))).to be(true)
    end

    it "is false for a blank image and for nil" do
      expect(described_class.art?(create(:image, user_id: admin.id))).to be(false)
      expect(described_class.art?(nil)).to be(false)
    end
  end
end
