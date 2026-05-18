require "rails_helper"

RSpec.describe Board, "AI word-suggestion methods", type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user, name: "Drinks") }

  def stub_client(method_name, content)
    fake_client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(method_name).and_return({ role: "assistant", content: content })
    fake_client
  end

  describe "#get_words" do
    let!(:image) { FactoryBot.create(:image, user: user, label: "water") }
    let!(:bi) do
      bi = FactoryBot.build(:board_image, board: board, image: image)
      bi.skip_create_voice_audio = true
      bi.save!
      bi
    end

    it "returns the additional_words array, lowercased and deduped against board labels" do
      stub_client(:get_additional_words, '{"additional_words":["Milk","JUICE","water","tea"]}')

      result = board.get_words("Drinks", 4)

      # "water" is already on the board (excluded); others are lowercased + uniqued
      expect(result).to eq(%w[milk juice tea])
    end

    it "returns nil when the response is blank" do
      stub_client(:get_additional_words, nil)
      expect(board.get_words("Drinks", 4)).to be_nil
    end

    it "returns nil on the NO ADDITIONAL WORDS sentinel" do
      stub_client(:get_additional_words, 'NO ADDITIONAL WORDS {"additional_words":["x"]}')
      expect(board.get_words("Drinks", 4)).to be_nil
    end

    it "returns nil when additional_words key is missing" do
      stub_client(:get_additional_words, '{"other":[1,2,3]}')
      expect(board.get_words("Drinks", 4)).to be_nil
    end

    it "passes board, name, count, exclude list, preview flag, and language to OpenAiClient" do
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new).and_return(fake_client)
      expect(fake_client).to receive(:get_additional_words) do |b, name, n, exclude, preview, lang, **kwargs|
        expect(b).to eq(board)
        expect(name).to eq("Drinks")
        expect(n).to eq(5)
        expect(exclude).to include("water")
        expect(preview).to eq(false)
        expect(lang).to eq(board.language)
        expect(kwargs[:profile]).to be_nil
        { content: '{"additional_words":[]}' }
      end

      board.get_words("Drinks", 5)
    end
  end

  describe "#get_word_suggestions" do
    it "returns the words array from a valid response" do
      stub_client(:get_word_suggestions, '{"words":["coffee","tea","soda"]}')

      expect(board.get_word_suggestions("Drinks", 3)).to eq(%w[coffee tea soda])
    end

    it "tolerates fenced and trailing-comma JSON" do
      stub_client(:get_word_suggestions, "```json\n{\"words\":[\"a\",\"b\",]}\n```")
      expect(board.get_word_suggestions("Drinks", 2)).to eq(%w[a b])
    end

    it "returns nil for blank response" do
      stub_client(:get_word_suggestions, nil)
      expect(board.get_word_suggestions("Drinks", 3)).to be_nil
    end

    it "returns nil on NO WORDS sentinel" do
      stub_client(:get_word_suggestions, "NO WORDS")
      expect(board.get_word_suggestions("Drinks", 3)).to be_nil
    end

    it "returns nil when 'words' key is missing" do
      stub_client(:get_word_suggestions, '{"other":["x"]}')
      expect(board.get_word_suggestions("Drinks", 3)).to be_nil
    end

    it "passes language and board_type to OpenAiClient" do
      board.update!(board_type: "static", language: "es")
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new).and_return(fake_client)
      expect(fake_client).to receive(:get_word_suggestions) do |name, n, exclude, board_type, language:, profile:|
        expect(board_type).to eq("static")
        expect(language).to eq("es")
        { content: '{"words":[]}' }
      end

      board.get_word_suggestions("Drinks", 3)
    end
  end

  describe "#get_social_story_word_suggestions" do
    it "returns the words array (story steps)" do
      stub_client(:get_social_story_word_suggestions, '{"words":["walk to the door","open the door","go inside"]}')

      result = board.get_social_story_word_suggestions("Going to school", 3, 5)
      expect(result).to eq(["walk to the door", "open the door", "go inside"])
    end

    it "returns nil for blank response" do
      stub_client(:get_social_story_word_suggestions, nil)
      expect(board.get_social_story_word_suggestions("X", 3, 5)).to be_nil
    end

    it "returns nil on NO WORDS sentinel" do
      stub_client(:get_social_story_word_suggestions, "NO WORDS available")
      expect(board.get_social_story_word_suggestions("X", 3, 5)).to be_nil
    end
  end

  describe "#get_word_suggestions_from_prompt" do
    it "returns the words array" do
      stub_client(:get_word_suggestions_from_prompt, '{"words":["one","two","three"]}')

      expect(board.get_word_suggestions_from_prompt("anything")).to eq(%w[one two three])
    end

    it "returns nil for blank response" do
      stub_client(:get_word_suggestions_from_prompt, nil)
      expect(board.get_word_suggestions_from_prompt("anything")).to be_nil
    end

    it "returns nil on NO WORDS sentinel" do
      stub_client(:get_word_suggestions_from_prompt, "NO WORDS for you")
      expect(board.get_word_suggestions_from_prompt("anything")).to be_nil
    end

    it "returns nil when 'words' key is missing" do
      stub_client(:get_word_suggestions_from_prompt, '{"different":["x"]}')
      expect(board.get_word_suggestions_from_prompt("anything")).to be_nil
    end
  end
end
