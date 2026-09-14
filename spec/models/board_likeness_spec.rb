require "rails_helper"

# A board's likeness override (settings["likeness"]): a likeness, the explicit
# off switch, or nothing (inherit from the communicator).
RSpec.describe Board, "likeness override" do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner) }

  def save_likeness(value)
    board.update!(settings: (board.settings || {}).merge("likeness" => value))
    board.reload.settings
  end

  it "normalizes a likeness on save, dropping unknown tokens" do
    expect(save_likeness("skin_tone" => "Medium", "hair_color" => "neon")["likeness"]).to eq("skin_tone" => "medium")
  end

  it "keeps the explicit off switch" do
    expect(save_likeness("mode" => "none")["likeness"]).to eq("mode" => "none")
  end

  it "removes the key when nothing usable is left, so the board inherits" do
    expect(save_likeness("skin_tone" => "teal")).not_to have_key("likeness")
  end

  it "leaves other settings alone" do
    board.update!(settings: { "disable_scroll" => true })

    expect(save_likeness("skin_tone" => "light")["disable_scroll"]).to be(true)
  end

  it "is not carried onto a copy in someone else's account" do
    save_likeness("skin_tone" => "light")

    copy = board.clone_with_images(create(:user).id, "Copy of it")

    expect(copy.settings).not_to have_key("likeness")
  end

  describe "who sees it" do
    before { save_likeness("skin_tone" => "brown") }

    it "is in the owner's payload" do
      expect(board.api_view(owner)[:settings]["likeness"]).to eq("skin_tone" => "brown")
    end

    # A published board is served to anyone.
    it "is withheld from other viewers and from anonymous public views" do
      expect(board.api_view(create(:user))[:settings]).not_to have_key("likeness")
      expect(board.api_view_with_predictive_images(nil)[:settings]).not_to have_key("likeness")
    end
  end
end
