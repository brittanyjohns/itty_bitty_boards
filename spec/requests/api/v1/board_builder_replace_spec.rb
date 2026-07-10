require "rails_helper"

# Replace flow for the Board Builder re-run guard: replace=true destroys ALL
# existing builder sets on the communicator (via the builder BoardGroup
# cascade) before building fresh, instead of stacking another ~15-board set.
# confirm=true keeps its legacy "stack another" meaning.
RSpec.describe "API::V1::BoardBuilder replace flow", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  before do
    allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob)
    user.update!(settings: user.settings.to_h.merge("board_group_limit" => 10))
    BuildBoardSetJob.clear
  end

  def build!(extra = {})
    post "/api/v1/board_builder",
         params: { communicator_id: communicator.id, template: "home" }.merge(extra).to_json,
         headers: headers
  end

  def built_root_id!
    build!
    expect(response).to have_http_status(:created)
    id = JSON.parse(response.body)["id"]
    BuildBoardSetJob.drain
    id
  end

  it "409 payload advertises the replace option and lists existing sets" do
    root_id = built_root_id!

    build!
    expect(response).to have_http_status(:conflict)
    body = JSON.parse(response.body)
    expect(body["error"]).to eq("board_builder_set_exists")
    expect(body["can_replace"]).to be(true)
    expect(body["existing_sets"]).to eq([
      { "root_id" => root_id, "name" => "Home", "built_at" => Board.find(root_id).created_at.as_json },
    ])
    # legacy top-level keys kept for the shipped frontend
    expect(body["existing_root_id"]).to eq(root_id)
  end

  it "replace=true destroys the old set (group + members + dashboard entry) and builds fresh" do
    old_root_id = built_root_id!
    old_group = user.board_groups.find_by(builder: true, root_board_id: old_root_id)
    old_member_ids = old_group.board_group_boards.pluck(:board_id)
    expect(old_member_ids.size).to be > 1

    build!(replace: true)
    expect(response).to have_http_status(:created)
    new_root_id = JSON.parse(response.body)["id"]

    expect(new_root_id).not_to eq(old_root_id)
    expect(BoardGroup.exists?(old_group.id)).to be(false)
    old_member_ids.each { |id| expect(Board.exists?(id)).to be(false) }
    expect(communicator.reload.child_boards.pluck(:board_id)).to eq([new_root_id])
  end

  it "replace=true destroys ALL stacked sets, not just the newest" do
    built_root_id!
    build!(confirm: true) # stack a second set (legacy behavior)
    expect(response).to have_http_status(:created)
    BuildBoardSetJob.drain
    expect(communicator.reload.builder_roots.count).to eq(2)

    build!(replace: true)
    expect(response).to have_http_status(:created)

    expect(communicator.reload.builder_roots.count).to eq(1)
    expect(communicator.child_boards.count).to eq(1)
  end

  it "replace works for a user at their board-set cap (destroy frees the slot first)" do
    built_root_id!
    user.update!(settings: user.settings.to_h.merge("board_group_limit" => user.reload.countable_board_group_count))

    build!(replace: true)
    expect(response).to have_http_status(:created)
  end

  it "confirm=true still stacks a second set" do
    built_root_id!

    expect {
      build!(confirm: true)
    }.to change { communicator.reload.child_boards.count }.by(1)
    expect(response).to have_http_status(:created)
    expect(communicator.builder_roots.count).to eq(2)
  end

  it "replace=true with no existing set just builds" do
    expect {
      build!(replace: true)
    }.to change { communicator.reload.child_boards.count }.by(1)
    expect(response).to have_http_status(:created)
  end

  it "replaces a legacy group-less builder root by destroying the root directly" do
    root_id = built_root_id!
    group = user.board_groups.find_by(builder: true, root_board_id: root_id)
    group.board_group_boards.delete_all
    group.delete # legacy shape: root exists, no builder group

    build!(replace: true)
    expect(response).to have_http_status(:created)
    expect(Board.exists?(root_id)).to be(false)
  end
end
