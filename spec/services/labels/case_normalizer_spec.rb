require "rails_helper"

RSpec.describe Labels::CaseNormalizer do
  describe ".normalize" do
    it "title cases a single lowercase word" do
      expect(described_class.normalize("swing")).to eq("Swing")
    end

    it "title cases every word of a multi-word label" do
      expect(described_class.normalize("all done")).to eq("All Done")
    end

    it "capitalizes a standalone i" do
      expect(described_class.normalize("i")).to eq("I")
    end

    context "when the text already carries deliberate casing" do
      it "leaves brand casing alone" do
        expect(described_class.normalize("iPad")).to eq("iPad")
      end

      it "leaves acronyms alone" do
        expect(described_class.normalize("TV")).to eq("TV")
      end

      it "leaves interior capitals alone" do
        expect(described_class.normalize("McDonald's")).to eq("McDonald's")
      end

      it "leaves an already Title Cased phrase alone" do
        expect(described_class.normalize("All Done")).to eq("All Done")
      end
    end

    context "with a phrase part of speech" do
      it "sentence cases instead of title casing" do
        expect(described_class.normalize("i want more please", part_of_speech: "phrase"))
          .to eq("I want more please")
      end

      it "capitalizes a standalone i anywhere in the phrase" do
        expect(described_class.normalize("can i go now", part_of_speech: "phrase"))
          .to eq("Can I go now")
      end

      it "capitalizes a contracted i" do
        expect(described_class.normalize("now i'm done", part_of_speech: "phrase"))
          .to eq("Now I'm done")
      end

      it "does not capitalize words that merely start with i" do
        expect(described_class.normalize("put it in there", part_of_speech: "phrase"))
          .to eq("Put it in there")
      end
    end

    context "with a non-English language" do
      it "sentence cases rather than applying English Title Case" do
        expect(described_class.normalize("todo listo", language: "es")).to eq("Todo listo")
      end

      it "does not apply the English standalone-i rule" do
        expect(described_class.normalize("si i no", language: "es")).to eq("Si i no")
      end

      it "still title cases regional English" do
        expect(described_class.normalize("all done", language: "en-US")).to eq("All Done")
      end
    end

    it "returns blank input unchanged" do
      expect(described_class.normalize(nil)).to eq("")
      expect(described_class.normalize("   ")).to eq("   ")
    end

    it "preserves the original spacing" do
      expect(described_class.normalize("all  done")).to eq("All  Done")
    end

    it "never downcases" do
      expect(described_class.normalize("HELP", part_of_speech: "phrase")).to eq("HELP")
    end
  end
end
