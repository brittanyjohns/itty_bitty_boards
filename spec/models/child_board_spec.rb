# == Schema Information
#
# Table name: child_boards
#
#  id                :bigint           not null, primary key
#  board_id          :bigint           not null
#  child_account_id  :bigint           not null
#  status            :string
#  settings          :jsonb
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  published         :boolean          default(FALSE)
#  favorite          :boolean          default(FALSE)
#  created_by_id     :bigint
#  original_board_id :bigint
#  layout            :jsonb
#  position          :integer
#
require "rails_helper"

RSpec.describe ChildBoard, type: :model do
  let(:user)         { create(:user) }
  let(:board)        { create(:board, user: user) }
  let(:communicator) { create(:child_account, user: user) }

  describe "uniqueness of (board_id, child_account_id)" do
    before { create(:child_board, board: board, child_account: communicator) }

    it "rejects a duplicate dashboard entry at the model layer" do
      dup = build(:child_board, board: board, child_account: communicator)
      expect(dup).not_to be_valid
      expect(dup.errors[:board_id]).to be_present
    end

    it "is enforced structurally by the unique index (validation-skipping inserts raise)" do
      expect {
        described_class.insert!({ board_id: board.id, child_account_id: communicator.id,
                                  created_at: Time.current, updated_at: Time.current })
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same board on a different communicator" do
      other = create(:child_account, user: user)
      expect(build(:child_board, board: board, child_account: other)).to be_valid
    end
  end

  describe "in_use recalculation on attach/detach" do
    it "flags a directly-attached board in_use on create (Board Builder path)" do
      expect(board.reload.in_use).to be(false)

      child_board = create(:child_board, board: board, child_account: communicator)

      expect(board.reload.in_use).to be(true)

      child_board.destroy!
      expect(board.reload.in_use).to be(false)
    end

    it "flags the clone source in_use via original_board (assign path)" do
      clone = create(:board, user: user, is_template: true)

      child_board = create(:child_board, board: clone, original_board: board, child_account: communicator)

      expect(board.reload.in_use).to be(true)
      expect(clone.reload.in_use).to be(true)

      child_board.destroy!
      expect(board.reload.in_use).to be(false)
      expect(clone.reload.in_use).to be(false)
    end

    it "keeps in_use true while another communicator still has the board" do
      other = create(:child_account, user: user)
      keeper = create(:child_board, board: board, child_account: communicator)
      create(:child_board, board: board, child_account: other)

      keeper.destroy!
      expect(board.reload.in_use).to be(true)
    end
  end

  describe "#public_card_view" do
    let(:child_board) { create(:child_board, board: board, child_account: communicator) }

    subject(:card) { child_board.public_card_view }

    # The drift guard. This card and Board#public_card_view feed the same
    # frontend component and the same PublicBoardCard type; maintaining them in
    # parallel is what dropped preset_display_image_url here, so a
    # communicator's board could not reach a cover its library twin resolved.
    # If Board grows a key, this fails until ChildBoard relays it.
    it "carries every key Board#public_card_view does" do
      expect(card.keys).to contain_exactly(
        :id, :board_id, :slug, :name,
        :display_image_url, :preview_image_url, :preset_display_image_url,
        :bg_color, :text_color,
      )
      expect(card.keys).to include(*board.public_card_view.keys)
    end

    # Locks the merge order — the one way delegating here breaks silently.
    # Board's card sets `id: id, board_id: id`, both the board's id.
    it "reports the child_board id and the board id separately" do
      expect(card[:id]).to eq(child_board.id)
      expect(card[:board_id]).to eq(board.id)
    end

    it "resolves the cover snapshot the column cannot reach" do
      board.update!(
        settings: board.settings.to_h.merge(
          "preset_display_image_url" => "https://cdn.example.com/cover.png",
        ),
      )
      board.update_column(:display_image_url, nil)

      expect(card[:preset_display_image_url]).to eq("https://cdn.example.com/cover.png")
    end

    # An unauthenticated page must never receive what api_view publishes:
    # added_by is the assigning user's EMAIL.
    it "publishes nothing that identifies a person" do
      expect(card.keys).not_to include(
        :added_by, :added_by_id, :board_owner_name, :board_owner_id,
        :settings, :in_use_by, :communicator_account_data,
      )
    end
  end

  # Favoriting is what puts a board on the communicator's public MySpeak page,
  # and Board#viewable_by? refuses an anonymous visitor an unpublished board —
  # so the card would render and then 404 on tap.
  describe "publishing on favorite" do
    let(:unpublished) { create(:board, user: user, published: false) }

    it "publishes the board when a row is created already favorited" do
      create(:child_board, board: unpublished, child_account: communicator, favorite: true)

      expect(unpublished.reload.published).to be true
    end

    it "publishes the board when #toggle_favorite turns it on" do
      child_board = create(:child_board, board: unpublished, child_account: communicator)

      expect { child_board.toggle_favorite }
        .to change { unpublished.reload.published }.from(false).to(true)
    end

    it "does not publish a board that is merely attached, not favorited" do
      create(:child_board, board: unpublished, child_account: communicator)

      expect(unpublished.reload.published).to be false
    end

    # /pb/<slug> may already be printed into an IEP or a QR code. Removing a
    # board from MySpeak must never break paper.
    it "leaves the board published when the favorite is turned back off" do
      child_board = create(:child_board, board: unpublished, child_account: communicator,
                                         favorite: true)

      expect { child_board.toggle_favorite }
        .not_to change { unpublished.reload.published }.from(true)
    end

    it "does not publish a board owned by another user" do
      foreign = create(:board, user: create(:user), published: false)
      create(:child_board, board: foreign, child_account: communicator, favorite: true)

      expect(foreign.reload.published).to be false
    end
  end

  # `child_boards.published` is a dead column — nothing in the app writes it —
  # so the serializers report the BOARD's flag, which is what actually gates
  # the public page.
  describe "#api_view published flag" do
    it "reports the board's published state, not the join row's" do
      board.update!(published: true)
      child_board = create(:child_board, board: board, child_account: communicator)

      expect(child_board.read_attribute(:published)).to be false
      expect(child_board.api_view[:published]).to be true
      expect(child_board.api_view_with_images[:published]).to be true
    end
  end
end
