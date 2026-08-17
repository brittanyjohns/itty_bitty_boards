require "rails_helper"

# The model-level half of marketplace protection: the guards that fire no
# matter which code path reaches the board. The controllers check up front and
# render a 409; these exist so a cascade, a rake task or a console session can't
# get around it.
RSpec.describe "Board marketplace protection" do
  let(:user) { FactoryBot.create(:user) }
  let(:root) { FactoryBot.create(:board, user: user, name: "Daily Routines", published: true, slug: "daily-routines") }
  let(:page) { FactoryBot.create(:board, user: user, name: "Snack Time", published: true, slug: "snack-time") }

  def publish_printable!(boards: [root, page])
    BoardPrintable.create!(
      board: root,
      status: "complete",
      board_ids: boards.map(&:id),
      etsy_listing_id: 1234567890,
    )
  end

  describe "deletion" do
    it "refuses to destroy a protected board" do
      publish_printable!

      expect { root.destroy }.to raise_error(Board::MarketplaceProtectedError)
      expect(Board.exists?(root.id)).to be true
    end

    it "refuses an interior page of the printed tree" do
      publish_printable!

      expect { page.destroy! }.to raise_error(Board::MarketplaceProtectedError)
      expect(Board.exists?(page.id)).to be true
    end

    it "leaves an unprotected board alone" do
      other = FactoryBot.create(:board, user: user)

      expect { other.destroy! }.not_to raise_error
    end

    # The guard is prepend: true, so it fires before the dependent: :destroy
    # cascades. Without that, every tile and printable is destroyed and rolled
    # back to reach the same refusal.
    it "does not destroy the board's tiles on the way to refusing" do
      publish_printable!
      image = FactoryBot.create(:image)
      root.add_image(image.id)

      expect { root.destroy }.to raise_error(Board::MarketplaceProtectedError)
      expect(root.reload.board_images.count).to eq(1)
    end

    # Raise rather than throw :abort, because this is the caller that would
    # swallow a false return: BoardGroup destroys its members with destroy_all,
    # which checks nothing. Aborting there would destroy the group and leave the
    # protected board orphaned — worse than the deletion.
    it "aborts a BoardGroup cascade whole, leaving every member intact" do
      # builder: true is what makes the group OWN its members and cascade the
      # destroy — a plain group only drops its memberships.
      group = FactoryBot.create(:board_group, user: user, builder: true)
      group.boards << root
      group.boards << page
      publish_printable!

      expect { group.destroy }.to raise_error(Board::MarketplaceProtectedError)
      expect(Board.exists?(root.id)).to be true
      expect(Board.exists?(page.id)).to be true
      expect(BoardGroup.exists?(group.id)).to be true
    end

    it "goes through once protection is waived" do
      printable = publish_printable!
      printable.waive_protection!(user: user)

      expect { page.reload.destroy! }.not_to raise_error
    end

    # Console/rake hatch. Deliberately not reachable from any request param.
    it "has an explicit console escape hatch" do
      publish_printable!

      expect { page.destroy_despite_marketplace_protection! }.not_to raise_error
      expect(Board.exists?(page.id)).to be false
    end
  end

  describe "unpublishing" do
    it "refuses to unpublish a protected board" do
      publish_printable!

      expect { root.update!(published: false) }.to raise_error(Board::MarketplaceProtectedError)
      expect(root.reload.published).to be true
    end

    it "allows publishing, which can't break printed paper" do
      publish_printable!
      root.update_column(:published, false)

      expect { root.reload.update!(published: true) }.not_to raise_error
    end

    it "allows an ordinary save that doesn't touch published" do
      publish_printable!

      expect { root.update!(description: "a description") }.not_to raise_error
    end
  end

  describe "slugs" do
    # freeze_published_slug REVERTS rather than raising, because the frontend
    # re-derives the slug from the name on every rename. That must stay true for
    # a protected board too — the raise belongs on the deliberate hatch, not on
    # the ordinary save.
    it "still reverts an ordinary slug change silently, without raising" do
      publish_printable!

      expect { root.update!(slug: "something-else") }.not_to raise_error
      expect(root.reload.slug).to eq("daily-routines")
    end

    # rename_slug! is the "I really mean it" hatch — and it's exactly the one
    # that would 404 a printed QR.
    it "refuses the deliberate rename hatch" do
      publish_printable!

      expect { root.rename_slug!("brand-new-slug") }.to raise_error(Board::MarketplaceProtectedError)
      expect(root.reload.slug).to eq("daily-routines")
    end

    it "renames when the second opt-in is set" do
      publish_printable!
      root.allow_marketplace_protected_change = true

      root.rename_slug!("brand-new-slug")

      expect(root.reload.slug).to eq("brand-new-slug")
    end
  end
end
