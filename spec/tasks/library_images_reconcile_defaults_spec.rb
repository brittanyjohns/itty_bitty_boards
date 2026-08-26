require "rails_helper"
require "rake"

# `docs.current` is the LIBRARY DEFAULT and is meant to be single-valued per
# image — Image#display_doc resolves `docs.current.last`, so several current
# docs leave the default arbitrary rather than curated. A merge that
# consolidated two images each carrying their own default left the survivor
# with both. ImageMergeJob reconciles this at merge time now; this task repairs
# the rows merged before it did.
RSpec.describe "library_images:reconcile_defaults" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("library_images:reconcile_defaults")
  end

  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:task) { Rake::Task["library_images:reconcile_defaults"] }

  before { task.reenable }
  after { ENV.delete("APPLY") }

  def library_image(label)
    create(:image, label: label, user_id: nil, is_private: false)
  end

  def ambiguous_image(label, count: 3)
    image = library_image(label)
    count.times { create(:doc, documentable: image, user_id: nil, current: true) }
    image
  end

  it "writes nothing without APPLY=1" do
    image = ambiguous_image("wagon")

    expect { task.invoke }.not_to change { image.docs.where(current: true).count }
  end

  it "collapses several current docs down to one" do
    image = ambiguous_image("wagon")
    ENV["APPLY"] = "1"

    task.invoke

    expect(image.reload.docs.where(current: true).count).to eq(1)
  end

  it "keeps the newest, so no image's resolved picture changes" do
    image = ambiguous_image("wagon")
    expected = image.docs.order(:id).last
    ENV["APPLY"] = "1"

    task.invoke

    expect(image.reload.docs.where(current: true).pluck(:id)).to eq([expected.id])
  end

  it "leaves an image that already has exactly one default alone" do
    image = library_image("kite")
    keeper = create(:doc, documentable: image, user_id: nil, current: true)
    create(:doc, documentable: image, user_id: nil)
    ENV["APPLY"] = "1"

    task.invoke

    expect(image.reload.docs.where(current: true).pluck(:id)).to eq([keeper.id])
  end

  it "never invents a default for an image that has none" do
    image = library_image("puddle")
    create(:doc, documentable: image, user_id: nil)
    ENV["APPLY"] = "1"

    task.invoke

    expect(image.reload.docs.where(current: true)).to be_empty
  end

  it "does not touch a user's own image" do
    user = create(:user)
    image = create(:image, label: "balloon", user_id: user.id)
    3.times { create(:doc, documentable: image, user_id: user.id, current: true) }
    ENV["APPLY"] = "1"

    task.invoke

    expect(image.reload.docs.where(current: true).count).to eq(3)
  end
end
