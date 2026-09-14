require "rails_helper"

# Board#find_or_create_images_from_word_list with a likeness: generation still
# only runs where it would anyway, a picture already drawn for this owner's look
# is reused for free, and another look's picture doesn't count as art.
RSpec.describe Board, "#find_or_create_images_from_word_list with a likeness" do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, board_type: "dynamic") }
  let(:communicator) do
    create(:child_account, user: owner, settings: { "likeness" => { "skin_tone" => "medium" } })
  end
  # A verb: its picture is someone doing it, which is the communicator.
  let!(:image) { create(:image, label: "jump", user: nil, is_private: false, part_of_speech: "verb") }

  before do
    GenerateImagesJob.jobs.clear
    allow_any_instance_of(Doc).to receive(:tile_url) { |doc| "https://cdn.example.com/doc_#{doc.id}.webp" }
  end

  def fill(**kwargs)
    board.find_or_create_images_from_word_list(["jump"], parts_of_speech: { "jump" => "verb" }, **kwargs)
  end

  # A likeness picture of "kite" would be the communicator holding a kite —
  # exactly the stray person the rule exists to keep out.
  it "never reuses a likeness picture for a word whose picture isn't the communicator" do
    kite = create(:image, label: "kite", user: nil, is_private: false, part_of_speech: "noun")
    create(:doc, documentable: kite, user: owner, data: { Doc::LIKENESS_KEY => communicator.likeness.fingerprint })

    board.find_or_create_images_from_word_list(["kite"], parts_of_speech: { "kite" => "noun" }, communicator: communicator)

    expect(board.board_images.find_by(image_id: kite.id).display_image_url.to_s).not_to include("doc_")
    expect(GenerateImagesJob.jobs.size).to eq(1)
  end

  def tile
    board.board_images.find_by(image_id: image.id)
  end

  it "tells the job which communicator the board is for" do
    fill(communicator: communicator)

    expect(GenerateImagesJob.jobs.size).to eq(1)
    expect(GenerateImagesJob.jobs.first["args"][2]).to eq("communicator_id" => communicator.id)
  end

  it "enqueues exactly as before with no communicator" do
    fill

    expect(GenerateImagesJob.jobs.first["args"].size).to eq(2)
  end

  it "reuses the owner's picture for this look instead of generating" do
    doc = create(:doc, documentable: image, user: owner,
                       data: { Doc::LIKENESS_KEY => communicator.likeness.fingerprint })

    fill(communicator: communicator)

    expect(GenerateImagesJob.jobs).to be_empty
    expect(tile.display_image_url).to eq("https://cdn.example.com/doc_#{doc.id}.webp")
  end

  it "does not treat another look's picture as the word's art" do
    create(:doc, documentable: image, user: owner, data: { Doc::LIKENESS_KEY => "some-other-look" })

    fill(communicator: communicator)

    expect(GenerateImagesJob.jobs.size).to eq(1)
  end

  # The decision stands: a likeness applies only where art would be generated
  # anyway. Library art is kept.
  it "keeps existing library art and generates nothing" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    create(:doc, documentable: image, user: admin)

    fill(communicator: communicator)

    expect(GenerateImagesJob.jobs).to be_empty
  end
end
