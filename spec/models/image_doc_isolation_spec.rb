require "rails_helper"

# An Image is a SHARED library row, and its docs are not. A doc owned by nil or
# DEFAULT_ADMIN_ID is library art everyone may see; a doc owned by anyone else
# is private to that user. Two fallbacks in Image#display_doc broke that: the
# admin viewer's `docs.last` shortcut and the unscoped `docs.last` tail, both of
# which handed out whichever doc was newest regardless of who made it — and
# display_doc feeds serializers, tile fallbacks, and the shared src_url.
RSpec.describe Image, "doc isolation between users" do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:alice) { create(:user) }
  let(:bob) { create(:user) }

  let(:image) { create(:image, user: admin, label: "apple", is_private: false) }

  before do
    allow_any_instance_of(Doc).to receive(:tile_url) { |doc| "https://cdn.example.com/doc_#{doc.id}.webp" }
  end

  context "when a library image's only doc is a regular user's" do
    let!(:alices_doc) { create(:doc, documentable: image, user: alice) }

    it "resolves it for its owner" do
      expect(image.display_doc(alice)).to eq(alices_doc)
    end

    it "never resolves it for another user" do
      expect(image.display_doc(bob)).to be_nil
    end

    it "never resolves it with no viewer" do
      expect(image.display_doc(nil)).to be_nil
    end

    it "never resolves it for the admin viewer" do
      expect(image.display_doc(admin)).to be_nil
    end

    it "is not written to the shared src_url by an unrelated save" do
      image.update_column(:src_url, nil)
      image.reload.update!(status: "finished")

      expect(image.reload.src_url).to be_blank
    end
  end

  context "when an image carries library art and a newer user doc" do
    let!(:library_doc) { create(:doc, documentable: image, user: admin) }
    let!(:alices_doc) { create(:doc, documentable: image, user: alice) }

    it "falls back to the library doc, not the newer user doc" do
      expect(image.display_doc(bob)).to eq(library_doc)
      expect(image.display_doc(nil)).to eq(library_doc)
      expect(image.display_doc(admin)).to eq(library_doc)
    end

    it "still gives the owner their own doc" do
      expect(image.display_doc(alice)).to eq(alices_doc)
    end

    it "lists only visible docs in api_view" do
      expect(image.api_view(bob)[:docs].map { |d| d[:id] }).to contain_exactly(library_doc.id)
      expect(image.api_view(alice)[:docs].map { |d| d[:id] }).to contain_exactly(library_doc.id, alices_doc.id)
    end
  end

  # A UserDoc is a pointer. One aimed at a doc its user could not otherwise see
  # (mark_as_current used to accept any doc id) must not become a way in.
  it "ignores a UserDoc pick that points at another user's doc" do
    library_doc = create(:doc, documentable: image, user: admin)
    alices_doc = create(:doc, documentable: image, user: alice)
    UserDoc.create!(user: bob, doc: alices_doc, image: image)

    expect(image.display_doc(bob)).to eq(library_doc)
  end

  # A user's own image is theirs: resolving it with no viewer uses its owner,
  # which is how their private uploads render on their own public board.
  it "resolves a user-owned image's own docs with no viewer" do
    own_image = create(:image, user: alice, label: "my dog", is_private: true)
    own_doc = create(:doc, documentable: own_image, user: alice)

    expect(own_image.display_doc(nil)).to eq(own_doc)
  end

  it "never falls through to a stranger's doc on an unowned image" do
    unowned = create(:image, user: nil, label: "pear")
    create(:doc, documentable: unowned, user: alice)

    expect(unowned.display_doc(nil)).to be_nil
    expect(unowned.display_doc(bob)).to be_nil
  end

  describe "BoardImage#update_to_default_doc!" do
    it "never repoints a tile at another user's doc" do
      create(:doc, documentable: image, user: alice)
      board = create(:board, user: bob)
      board.add_image(image.id)
      tile = board.board_images.find_by(image_id: image.id)
      tile.update_column(:display_image_url, nil)

      tile.update_to_default_doc!

      expect(tile.reload.display_image_url).to be_nil
    end
  end
end
