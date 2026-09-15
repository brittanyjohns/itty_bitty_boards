require "rails_helper"

RSpec.describe CanvaTemplatesValidator do
  describe ".allowed_url?" do
    it "allows only https Canva design and short links" do
      expect(described_class.allowed_url?("https://www.canva.com/design/DAG/x/view")).to be(true)
      expect(described_class.allowed_url?("https://canva.com/design/DAG/x/view")).to be(true)
      expect(described_class.allowed_url?("https://canva.link/abc")).to be(true)

      expect(described_class.allowed_url?("https://canva.link/")).to be(false)
      expect(described_class.allowed_url?("http://www.canva.com/design/DAG/x")).to be(false)
      expect(described_class.allowed_url?("https://www.canva.com/templates/x")).to be(false)
      expect(described_class.allowed_url?("https://canva.com.example.com/design/x")).to be(false)
      expect(described_class.allowed_url?("not a url at all ::")).to be(false)
    end
  end

  it "is the one allowlist both models read" do
    expect(KitPage::CANVA_DESIGN_HOSTS).to equal(described_class::DESIGN_HOSTS)
    expect(KitPage::CANVA_SHORT_HOSTS).to equal(described_class::SHORT_HOSTS)
    expect(KitPage.validators_on(:canva_templates).map(&:class)).to include(described_class)
    expect(PrintableProduct.validators_on(:canva_templates).map(&:class)).to include(described_class)
  end

  it ".usable drops rows without a link" do
    rows = [{ "label" => "A", "url" => "https://canva.link/a" }, { "label" => "B", "url" => "" }, "junk"]

    expect(described_class.usable(rows)).to eq([rows.first])
  end
end
