require "rails_helper"

# A picture drawn with a communicator likeness belongs to the tiles it was
# drawn for. It is never library art (even admin-owned), never a UserDoc pick,
# and never what generic resolution returns — or kid A's look becomes the word's
# picture on kid B's board.
RSpec.describe Image, "likeness docs" do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { create(:user) }
  let(:stranger) { create(:user) }
  let(:image) { create(:image, user: admin, label: "swing", is_private: false) }

  def likeness_doc(user:, fingerprint: "abc123")
    create(:doc, documentable: image, user: user, data: { Doc::LIKENESS_KEY => fingerprint })
  end

  before do
    allow_any_instance_of(Doc).to receive(:tile_url) { |doc| "https://cdn.example.com/doc_#{doc.id}.webp" }
  end

  it "gets no UserDoc pick" do
    doc = likeness_doc(user: owner)

    expect(UserDoc.where(doc_id: doc.id)).to be_empty
  end

  it "is not what the owner's generic resolution returns" do
    library = create(:doc, documentable: image, user: admin)
    likeness_doc(user: owner)

    expect(image.display_doc(owner)).to eq(library)
  end

  it "is resolved for nobody when it is the only doc" do
    likeness_doc(user: owner)

    expect(image.display_doc(owner)).to be_nil
    expect(image.display_doc(nil)).to be_nil
  end

  it "is not library art even when the admin owns it" do
    doc = likeness_doc(user: admin)

    expect(doc).not_to be_library
    expect(image.display_doc(stranger)).to be_nil
    expect(image.docs.for_user(stranger)).not_to include(doc)
    expect(image.docs.for_user(admin)).to include(doc)
  end

  it "is listed for its owner and nobody else" do
    doc = likeness_doc(user: owner)

    expect(image.visible_docs_for(owner)).to include(doc)
    expect(image.visible_docs_for(stranger)).not_to include(doc)
  end

  describe "#likeness_doc_for" do
    it "finds the owner's picture for that look only" do
      mine = likeness_doc(user: owner, fingerprint: "look-a")
      likeness_doc(user: owner, fingerprint: "look-b")
      likeness_doc(user: stranger, fingerprint: "look-a")

      expect(image.likeness_doc_for(user_id: owner.id, fingerprint: "look-a")).to eq(mine)
      expect(image.likeness_doc_for(user_id: owner.id, fingerprint: "look-c")).to be_nil
    end
  end

  describe "#create_image_doc" do
    it "never makes a likeness doc the library default" do
      doc = likeness_doc(user: admin)
      allow(image).to receive(:create_image).and_return(doc)
      expect(image).not_to receive(:set_library_default_doc!)

      image.create_image_doc(admin.id, "a prompt", likeness_fingerprint: "abc123")

      expect(doc.reload.current).to be(false)
    end

    it "hands the fingerprint to the save" do
      expect(image).to receive(:create_image)
        .with(owner.id, "a prompt", transparent: true, likeness_fingerprint: "abc123").and_return(nil)

      image.create_image_doc(owner.id, "a prompt", likeness_fingerprint: "abc123")
    end
  end
end
