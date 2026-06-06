# spec/requests/api/board_images_label_case_spec.rb
#
# Covers the bulk display-label case transform on
# PUT /api/board_images/update (BoardImagesController#update_multiple).
# The frontend bulk-edit drawer sends payload[:label_case] = upper|lower|sentence
# and the backend rewrites each selected board_image's display_label.

require "rails_helper"

RSpec.describe "BoardImages bulk label_case", type: :request do
  def j
    JSON.parse(response.body) rescue {}
  end

  before do
    allow_any_instance_of(API::ApplicationController)
      .to receive(:authenticate_token!).and_return(true)
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)
  end

  let!(:user)  { create(:user) }
  let!(:board) { create(:board, user: user) }
  let!(:image) { create(:image, user: user, label: "i WANT more") }
  let!(:board_image) do
    create(:board_image, board: board, image: image).tap do |bi|
      bi.update!(display_label: "i WANT more")
    end
  end

  def put_label_case(label_case)
    put "/api/board_images/update",
        params: {
          board_id: board.id,
          board_image_ids: [board_image.id],
          payload: { label_case: label_case },
        }
  end

  it "upcases the display label" do
    put_label_case("upper")
    expect(response.status).to eq(200)
    expect(board_image.reload.display_label).to eq("I WANT MORE")
  end

  it "downcases the display label" do
    put_label_case("lower")
    expect(response.status).to eq(200)
    expect(board_image.reload.display_label).to eq("i want more")
  end

  it "sentence-cases the display label (first letter up, rest down)" do
    put_label_case("sentence")
    expect(response.status).to eq(200)
    expect(board_image.reload.display_label).to eq("I want more")
  end

  it "leaves the display label untouched when no label_case is sent" do
    put "/api/board_images/update",
        params: {
          board_id: board.id,
          board_image_ids: [board_image.id],
          payload: { hide_labels: false },
        }
    expect(response.status).to eq(200)
    expect(board_image.reload.display_label).to eq("i WANT more")
  end

  it "falls back to the image label when display_label is blank" do
    board_image.update_column(:display_label, nil)
    put_label_case("upper")
    expect(response.status).to eq(200)
    expect(board_image.reload.display_label).to eq("I WANT MORE")
  end
end
