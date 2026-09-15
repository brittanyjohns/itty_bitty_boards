require "rails_helper"

RSpec.describe Boards::Printables::Fonts do
  it "keeps the print layouts on Nunito alone" do
    css = described_class.face_css

    expect(css.scan("font-family: 'Nunito'").size).to eq(2)
    expect(css).not_to include("Caveat", "Fredoka")
  end

  it "inlines Nunito, Fredoka and Caveat for the styled slides" do
    css = described_class.styled_face_css

    expect(css).to include(described_class.face_css)
    expect(css).to include("font-family: 'Fredoka'")
    expect(css.scan("font-family: 'Caveat'").size).to eq(2)
    expect(css).not_to include("url(http")
  end

  it "ships the Caveat files with their license" do
    described_class::CAVEAT_SUBSETS.each_key do |file|
      expect(described_class::CAVEAT_DIR.join(file)).to exist
    end
    expect(described_class::CAVEAT_DIR.join("OFL.txt").read).to include("SIL Open Font License")
  end
end
