require "rails_helper"
require "rake"

# Doc isolation stops NEW leaks; URLs copied from another user's private doc
# before the fix are persisted columns and stay put. This task counts them and
# must never repair anything — display_image_url is per-tile user content.
RSpec.describe "images:doc_isolation_report" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("images:doc_isolation_report")
  end

  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:task) { Rake::Task["images:doc_isolation_report"] }
  let(:alice) { create(:user) }
  let(:bob) { create(:user) }
  let(:image) { create(:image, user: admin, label: "apple", is_private: false) }
  let!(:alices_doc) { create(:doc, documentable: image, user: alice) }
  let(:leaked_url) { "https://cdn.example.com/doc_#{alices_doc.id}.webp" }

  before do
    task.reenable
    allow_any_instance_of(Doc).to receive(:tile_url) { |doc| "https://cdn.example.com/doc_#{doc.id}.webp" }
  end

  def leak_onto_bobs_board!
    board = create(:board, user: bob)
    board.add_image(image.id)
    board.board_images.find_by(image_id: image.id).tap { |bi| bi.update_column(:display_image_url, leaked_url) }
  end

  it "reports a src_url and a tile pointing at another user's private doc" do
    image.update_column(:src_url, leaked_url)
    leak_onto_bobs_board!

    expect { task.invoke }.to output(
      /src_url pointing at another user's private doc: 1.*tiles on a board not owned by the doc's owner:\s+1/m,
    ).to_stdout
  end

  it "does not count the doc owner's own tile" do
    board = create(:board, user: alice)
    board.add_image(image.id)
    board.board_images.find_by(image_id: image.id).update_column(:display_image_url, leaked_url)

    expect { task.invoke }.to output(/tiles on a board not owned by the doc's owner:\s+0/).to_stdout
  end

  it "changes nothing" do
    image.update_column(:src_url, leaked_url)
    tile = leak_onto_bobs_board!

    expect { task.invoke }.to output.to_stdout

    expect(image.reload.src_url).to eq(leaked_url)
    expect(tile.reload.display_image_url).to eq(leaked_url)
  end
end
