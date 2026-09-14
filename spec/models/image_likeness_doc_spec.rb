require "rails_helper"

# A picture drawn with a communicator likeness is PICKABLE, never a DEFAULT.
# An admin-owned one is shared library art — listed for everyone, and any user
# may choose it — but nothing resolves to one on its own (display_doc's
# fallback, docs.current, src_url), or kid A's look becomes the word's picture
# on kid B's board. A likeness doc owned by anyone else stays private.
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

  def pick!(user, doc)
    UserDoc.create!(user_id: user.id, doc_id: doc.id, image_id: image.id)
  end

  def likeness_result(tokens = { "skin_tone" => "brown" }, age_band: nil)
    Images::LikenessResolver::Result.new(likeness: CommunicatorLikeness.from_hash(tokens), age_band: age_band)
  end

  before do
    allow_any_instance_of(Doc).to receive(:tile_url) { |doc| "https://cdn.example.com/doc_#{doc.id}.webp" }
  end

  it "gets no automatic UserDoc pick" do
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

  describe "owned by the admin" do
    it "is shared library art, listed for every user" do
      doc = likeness_doc(user: admin)

      expect(doc).to be_library
      expect(doc).to be_shared_likeness
      expect(doc.visible_to?(stranger)).to be(true)
      expect(image.docs.for_user(stranger)).to include(doc)
      expect(image.docs.for_user(nil)).to include(doc)
      expect(image.visible_docs_for(stranger)).to include(doc)
    end

    it "is never the word's default for anyone" do
      likeness_doc(user: admin)

      expect(image.display_doc(stranger)).to be_nil
      expect(image.display_doc(admin)).to be_nil
    end

    it "loses the fallback to ordinary library art" do
      library = create(:doc, documentable: image, user: admin)
      likeness_doc(user: admin)

      expect(image.display_doc(stranger)).to eq(library)
    end

    it "resolves for a user who picked it" do
      create(:doc, documentable: image, user: admin)
      doc = likeness_doc(user: admin)
      pick!(stranger, doc)

      expect(image.display_doc(stranger)).to eq(doc)
    end

    it "can't be made the library default" do
      doc = likeness_doc(user: admin)

      expect(image.set_library_default_doc!(doc, actor: admin)).to be(false)
      expect(doc.reload.current).to be(false)
    end

    it "never becomes the shared src_url through a user's pick" do
      library = create(:doc, documentable: image, user: admin, current: true)
      image.update_column(:src_url, library.tile_url)
      pick!(stranger, likeness_doc(user: admin))

      image.update_to_src_url!(stranger)

      expect(image.reload.src_url).to eq(library.tile_url)
    end
  end

  describe "owned by a regular user" do
    it "is listed for its owner and nobody else" do
      doc = likeness_doc(user: owner)

      expect(image.visible_docs_for(owner)).to include(doc)
      expect(image.visible_docs_for(stranger)).not_to include(doc)
      expect(image.docs.for_user(stranger)).not_to include(doc)
    end

    it "doesn't resolve even through a pick" do
      library = create(:doc, documentable: image, user: admin)
      pick!(owner, likeness_doc(user: owner))

      expect(image.display_doc(owner)).to eq(library)
    end
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

      image.create_image_doc(admin.id, "a prompt", likeness: likeness_result)

      expect(doc.reload.current).to be(false)
    end

    it "hands the likeness to the save" do
      result = likeness_result
      expect(image).to receive(:create_image)
        .with(owner.id, "a prompt", transparent: true, likeness: result).and_return(nil)

      image.create_image_doc(owner.id, "a prompt", likeness: result)
    end
  end
end
