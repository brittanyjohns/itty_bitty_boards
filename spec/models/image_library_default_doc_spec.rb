require "rails_helper"

# `docs.current` is a single global boolean on a SHARED library row. Every
# account resolving that Image with no preference of their own falls back to
# it, so it is the LIBRARY DEFAULT, not "this user's pick" — and only someone
# who may edit the Image may move it.
RSpec.describe Image, "#set_library_default_doc!" do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { create(:user) }
  let(:stranger) { create(:user) }

  let(:image) { create(:image, user: owner, label: "apple") }
  let!(:old_doc) { create(:doc, documentable: image, user: owner, current: true) }
  let!(:new_doc) { create(:doc, documentable: image, user: owner) }

  it "lets the image's owner move it, clearing the previous default" do
    expect(image.set_library_default_doc!(new_doc, actor: owner)).to be(true)

    expect(new_doc.reload.current).to be(true)
    expect(old_doc.reload.current).to be(false)
  end

  it "lets an admin move it on someone else's image (the shared library)" do
    expect(image.set_library_default_doc!(new_doc, actor: admin)).to be(true)
    expect(new_doc.reload.current).to be(true)
  end

  it "refuses an unrelated user and writes nothing" do
    expect(image.set_library_default_doc!(new_doc, actor: stranger)).to be(false)

    expect(new_doc.reload.current).to be(false)
    expect(old_doc.reload.current).to be(true)
  end

  it "refuses with no actor" do
    expect(image.set_library_default_doc!(new_doc, actor: nil)).to be(false)
    expect(new_doc.reload.current).to be(false)
  end

  it "refuses a doc belonging to a different image" do
    other_doc = create(:doc, documentable: create(:image, user: owner, label: "pear"), user: owner)

    expect(image.set_library_default_doc!(other_doc, actor: admin)).to be(false)
    expect(other_doc.reload.current).to be(false)
  end
end
