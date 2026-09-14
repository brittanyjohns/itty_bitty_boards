require "rails_helper"

# Who a generated Doc belongs to decides who may see it: a doc owned by nil or
# DEFAULT_ADMIN_ID is library art for everyone. This job used to generate as
# `image.user_id`, which is nil for every word-list image — so a regular user's
# board fill or paid regenerate minted public library art, and on an
# admin-owned image it moved the library default for every account.
RSpec.describe GenerateImagesJob, "doc ownership", type: :job do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, board_type: "dynamic") }
  let(:image) { create(:image, user: nil, label: "kite") }

  before do
    board.add_image(image.id)
    allow_any_instance_of(Doc).to receive(:tile_url).and_return("https://cdn.example.com/kite.webp")
  end

  def expect_generated_as(user_id)
    expect_any_instance_of(Image).to receive(:create_image_doc) do |_img, generating_user_id, _prompt|
      expect(generating_user_id).to eq(user_id)
      nil
    end
  end

  it "generates as the board's owner, not the image's (often nil) creator" do
    expect_generated_as(owner.id)

    described_class.new.perform([image.id], board.id)
  end

  # Whoever enqueued the run is irrelevant: tile art belongs to the board's
  # owner, so an admin regenerating a family's board for support must not mint
  # library art out of it.
  it "generates as the board's owner even when the image is admin-owned" do
    library_image = create(:image, user: admin, label: "boat")
    board.add_image(library_image.id)
    expect_generated_as(owner.id)

    described_class.new.perform([library_image.id], board.id)
  end

  it "generates as the admin on an admin board, so library art still grows" do
    admin_board = create(:board, user: admin, board_type: "dynamic")
    admin_board.add_image(image.id)
    expect_generated_as(admin.id)

    described_class.new.perform([image.id], admin_board.id)
  end

  describe "replace_current" do
    let(:library_image) { create(:image, user: admin, label: "sun") }
    let!(:library_doc) { create(:doc, documentable: library_image, user: admin, current: true) }

    before { board.add_image(library_image.id) }

    it "never demotes the library default for a user who may not edit the image" do
      users_doc = create(:doc, documentable: library_image, user: owner)
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(users_doc)

      described_class.new.perform([library_image.id], board.id, { "replace_current" => true })

      expect(library_doc.reload.current).to be(true)
    end

    it "still demotes the old default when an admin regenerates" do
      admin_board = create(:board, user: admin, board_type: "dynamic")
      admin_board.add_image(library_image.id)
      new_doc = create(:doc, documentable: library_image, user: admin)
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(new_doc)

      described_class.new.perform([library_image.id], admin_board.id, { "replace_current" => true })

      expect(library_doc.reload.current).to be(false)
    end
  end
end
