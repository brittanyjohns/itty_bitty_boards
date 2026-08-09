require "rails_helper"

RSpec.describe Labels::CaseNormalizer do
  describe ".normalize" do
    it "leaves a single lowercase word lowercase" do
      expect(described_class.normalize("swing")).to eq("swing")
    end

    it "leaves every word of a multi-word label lowercase" do
      expect(described_class.normalize("all done")).to eq("all done")
    end

    it "capitalizes a standalone i" do
      expect(described_class.normalize("i")).to eq("I")
    end

    it "capitalizes a standalone i anywhere in a multi-word label" do
      expect(described_class.normalize("was it i")).to eq("was it I")
    end

    # "Deliberate" means a capital the author could only have typed on purpose —
    # one PAST the first letter. A plain leading capital is what a word-list
    # line, an LLM's JSON label, or ordinary typing produces, so it carries no
    # intent and must not exempt a tile from the lowercase default.
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

      it "judges each word on its own, so styling survives beside a folded word" do
        expect(described_class.normalize("My iPad")).to eq("my iPad")
      end
    end

    context "when the text carries only an accidental leading capital" do
      it "folds a single Title Cased word down to the lowercase default" do
        expect(described_class.normalize("Fun")).to eq("fun")
      end

      it "folds every word of a Title Cased label" do
        expect(described_class.normalize("All Done")).to eq("all done")
      end

      it "still capitalizes a standalone I" do
        expect(described_class.normalize("Me And I")).to eq("me and I")
      end

      it "preserves the original spacing while folding" do
        expect(described_class.normalize("All  Done")).to eq("all  done")
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

      it "folds a Title Cased phrase down to sentence case" do
        expect(described_class.normalize("All Done Now", part_of_speech: "phrase"))
          .to eq("All done now")
      end

      it "keeps a styled word styled mid-phrase" do
        expect(described_class.normalize("i want my iPad", part_of_speech: "phrase"))
          .to eq("I want my iPad")
      end

      it "does not force a sentence capital onto a styled leading word" do
        expect(described_class.normalize("iPad is broken", part_of_speech: "phrase"))
          .to eq("iPad is broken")
      end
    end

    context "with a non-English language" do
      it "sentence cases rather than applying English Title Case" do
        expect(described_class.normalize("todo listo", language: "es")).to eq("Todo listo")
      end

      it "does not apply the English standalone-i rule" do
        expect(described_class.normalize("si i no", language: "es")).to eq("Si i no")
      end

      it "still applies the lowercase default for regional English" do
        expect(described_class.normalize("all done", language: "en-US")).to eq("all done")
      end
    end

    it "returns blank input unchanged" do
      expect(described_class.normalize(nil)).to eq("")
      expect(described_class.normalize("   ")).to eq("   ")
    end

    it "preserves the original spacing" do
      expect(described_class.normalize("all  done")).to eq("all  done")
    end

    it "preserves spacing around a capitalized standalone i" do
      expect(described_class.normalize("was  it  i")).to eq("was  it  I")
    end

    it "never downcases a word whose casing was deliberate" do
      expect(described_class.normalize("HELP", part_of_speech: "phrase")).to eq("HELP")
      expect(described_class.normalize("HELP")).to eq("HELP")
    end
  end
end
