require "rails_helper"

RSpec.describe GenerateImagesJob, "communicator likeness", type: :job do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, board_type: "dynamic") }
  let(:image) { create(:image, user: nil, label: "swing", part_of_speech: "verb") }
  let(:look) { { "skin_tone" => "dark_brown", "hair_style" => "braids", "hair_color" => "black" } }
  let(:communicator) do
    create(:child_account, user: owner, settings: { "likeness" => look }, details: { "age_band" => "7-10" })
  end

  before { board.add_image(image.id) }

  def capture_generation
    captured = {}
    expect_any_instance_of(Image).to receive(:create_image_doc) do |_img, user_id, prompt, **kwargs|
      captured.merge!(
        user_id: user_id, prompt: prompt,
        fingerprint: kwargs[:likeness]&.fingerprint, likeness: kwargs[:likeness],
      )
      nil
    end
    yield
    captured
  end

  it "draws the attached communicator's likeness and stamps its fingerprint" do
    ChildBoard.create!(child_account: communicator, board: board)

    result = capture_generation { described_class.new.perform([image.id], board.id) }

    expect(result[:prompt]).to include("If the picture shows a person, draw that person as a child with dark brown skin and black braided hair")
    expect(result[:fingerprint]).to eq(communicator.likeness.fingerprint)
    expect(result[:user_id]).to eq(owner.id)
    # The tag the save stamps: the look and age band, not the communicator.
    expect(Doc.likeness_data(result[:likeness])).to include(
      Doc::LIKENESS_TRAITS_KEY => communicator.likeness.to_h,
      Doc::LIKENESS_AGE_BAND_KEY => "7-10",
    )
  end

  it "uses a communicator named in the options for a board that isn't attached" do
    result = capture_generation do
      described_class.new.perform([image.id], board.id, { "communicator_id" => communicator.id })
    end

    expect(result[:fingerprint]).to eq(communicator.likeness.fingerprint)
  end

  it "sends the plain house prompt with no likeness" do
    result = capture_generation { described_class.new.perform([image.id], board.id) }

    expect(result[:prompt]).not_to include("If the picture shows a person")
    expect(result[:fingerprint]).to be_nil
  end

  it "never demotes the library default for a likeness run" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    library_image = create(:image, user: admin, label: "slide")
    library_doc = create(:doc, documentable: library_image, user: admin, current: true)
    admin_board = create(:board, user: admin, board_type: "dynamic")
    admin_board.add_image(library_image.id)
    admin_board.update!(settings: admin_board.settings.merge("likeness" => { "skin_tone" => "light" }))
    new_doc = create(:doc, documentable: library_image, user: admin, data: { Doc::LIKENESS_KEY => "x" })
    allow_any_instance_of(Image).to receive(:create_image_doc).and_return(new_doc)
    allow_any_instance_of(Doc).to receive(:tile_url).and_return("https://cdn.example.com/slide.webp")

    described_class.new.perform([library_image.id], admin_board.id, { "replace_current" => true })

    expect(library_doc.reload.current).to be(true)
  end
end
