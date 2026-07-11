require "rails_helper"

RSpec.describe BoardDestroyCleanupJob do
  subject(:run) { described_class.new.perform(board_id) }

  let(:user)     { create(:user) }
  let(:board)    { create(:board, user: user) }
  let(:board_id) { board.id }

  it "nullifies users.editable_board_id pointing at the board" do
    user.update_columns(editable_board_id: board_id)
    run
    expect(user.reload.editable_board_id).to be_nil
  end

  it "strips matching pointer keys from user settings, leaving other keys" do
    user.update_columns(settings: {
      "dynamic_board_id" => board_id,
      "phrase_board_id" => board_id.to_s,
      "board_limit" => 5,
    })
    run
    settings = user.reload.settings
    expect(settings).not_to have_key("dynamic_board_id")
    expect(settings).not_to have_key("phrase_board_id")
    expect(settings["board_limit"]).to eq(5)
  end

  it "strips matching pointer keys from child_account settings" do
    communicator = create(:child_account, user: user)
    communicator.update_columns(settings: { "phrase_board_id" => board_id })
    run
    expect(communicator.reload.settings).not_to have_key("phrase_board_id")
  end

  it "leaves pointers at OTHER boards alone" do
    other = create(:board, user: user)
    user.update_columns(settings: { "phrase_board_id" => other.id }, editable_board_id: other.id)
    run
    expect(user.reload.settings["phrase_board_id"]).to eq(other.id)
    expect(user.editable_board_id).to eq(other.id)
  end

  it "destroys scenarios generated from the board" do
    scenario = create(:scenario, user: user, board_id: board_id)
    run
    expect(Scenario.exists?(scenario.id)).to be false
  end

  it "leaves word_events untouched (analytics history)" do
    event = WordEvent.create!(user: user, board_id: board_id, word: "go")
    run
    expect(WordEvent.exists?(event.id)).to be true
    expect(event.reload.board_id).to eq(board_id)
  end

  it "is idempotent and tolerates the board row being gone" do
    user.update_columns(editable_board_id: board_id, settings: { "dynamic_board_id" => board_id })
    board.destroy!
    expect { 2.times { run } }.not_to raise_error
    expect(user.reload.editable_board_id).to be_nil
    expect(user.settings).not_to have_key("dynamic_board_id")
  end
end
