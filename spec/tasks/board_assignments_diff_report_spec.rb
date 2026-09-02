require "rails_helper"

# The diagnostic behind the migration decision. Its first version paired tiles
# by POSITION, so a reordered board reported every field as diverging at once —
# which is what made 25 invisible boards look like they had been relabelled.
RSpec.describe "board_assignments:diff_report", type: :task do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:owner) { create(:user, plan_type: "pro") }
  let(:communicator) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE, passcode: "ownerpw1")
  end
  let!(:source) { create(:board, user: owner, name: "Home") }

  before do
    %w[want more stop].each_with_index do |label, i|
      create(:board_image, board: source, image: create(:image, label: label), position: i)
    end
  end

  def legacy_assignment!
    root = Boards::SetCloner.new(source, owner: owner, communicator: communicator,
                                         voice: communicator.voice, name: source.name,
                                         out_of_set: :keep).call
    Board.where(id: root.id).update_all(is_template: true)
    [communicator.child_boards.find_by(board_id: root.id), root.reload]
  end

  def run_report
    task = Rake::Task["board_assignments:diff_report"]
    task.reenable
    out = StringIO.new
    $stdout = out
    task.invoke
    out.string
  ensure
    $stdout = STDOUT
  end

  it "reports no divergence for an untouched clone" do
    legacy_assignment!
    expect(run_report).to match(/0 clone\(s\) differ/)
  end

  # The regression this exists for: reordering must not read as a relabel.
  it "does not report label/bg_color divergence when only the tile ORDER differs" do
    _cb, clone = legacy_assignment!
    tiles = clone.board_images.order(:position).to_a
    tiles.first.update_column(:position, 99)

    output = run_report
    expect(output).not_to match(/^\s+label: /)
    expect(output).not_to match(/^\s+bg_color: /)
  end

  it "classifies a relabelled tile as a content_edit" do
    _cb, clone = legacy_assignment!
    clone.board_images.find_by(label: "want").update!(label: "need", display_label: "need")

    output = run_report
    expect(output).to match(/content_edit: 1/)
  end

  it "classifies a picture-only difference as art_only" do
    _cb, clone = legacy_assignment!
    clone.board_images.find_by(label: "want")
         .update_column(:display_image_url, "https://cdn.test/older-apple.png")

    output = run_report
    expect(output).to match(/art_only: 1/)
    expect(output).not_to match(/content_edit: /)
  end

  it "classifies an added tile as structural" do
    _cb, clone = legacy_assignment!
    create(:board_image, board: clone, image: create(:image, label: "extra"))

    expect(run_report).to match(/structural: 1/)
  end
end
