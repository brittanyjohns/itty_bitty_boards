require "rails_helper"

RSpec.describe GenerateImageJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:image) { FactoryBot.create(:image, user: user, label: "apple", part_of_speech: "noun") }
  let(:doc) { instance_double(Doc, tile_url: "https://cdn.example.com/apple.webp") }

  def captured_prompt_for(options)
    captured = nil
    allow_any_instance_of(Image).to receive(:create_image_doc) do |_img, _uid, prompt, **_kw|
      captured = prompt
      doc
    end
    allow(doc).to receive(:update)

    described_class.new.perform(image.id, user.id, options)
    captured
  end

  describe "composing the prompt" do
    # Callers such as Doc#regenerate and images#create pass no prompt at all.
    # This used to raise NoMethodError on nil and mark the image "failed".
    it "generates from the label when no prompt is supplied" do
      prompt = captured_prompt_for({})

      expect(prompt).to include("representing 'apple'")
      expect(image.reload.status).not_to eq("failed")
    end

    it "does not raise when options is not a hash" do
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(doc)
      allow(doc).to receive(:update)

      expect { described_class.new.perform(image.id, user.id, nil) }.not_to raise_error
    end

    it "wraps a user's prompt in the house envelope" do
      prompt = captured_prompt_for({ "image_prompt" => "a green apple on a wooden table" })

      expect(prompt).to include("a green apple on a wooden table")
      expect(prompt).to include("Do not include any text")
    end

    it "honors an explicit style option" do
      prompt = captured_prompt_for({ "style" => "illustrated" })

      expect(prompt).to include("simple, friendly illustration")
    end

    # image_prompt holds the user's intent, never the composed prompt —
    # otherwise each regeneration would wrap the previous envelope in a new one.
    it "stores only the user's intent, not the composed prompt" do
      captured_prompt_for({ "image_prompt" => "a green apple" })

      expect(image.reload.image_prompt).to eq("a green apple")
    end

    it "leaves a menu image's own prompt untouched" do
      menu_image = FactoryBot.create(:image, user: user, image_type: "menu",
                                             image_prompt: "A burger. Menu photo.")
      captured = nil
      allow_any_instance_of(Image).to receive(:create_image_doc) do |_img, _uid, prompt, **_kw|
        captured = prompt
        doc
      end
      allow(doc).to receive(:update)

      described_class.new.perform(menu_image.id, user.id, {})

      expect(captured).to eq("A burger. Menu photo.")
    end
  end

  describe "transparency" do
    it "requests transparency by default" do
      transparent = nil
      allow_any_instance_of(Image).to receive(:create_image_doc) do |_img, _uid, _prompt, **kw|
        transparent = kw[:transparent]
        doc
      end
      allow(doc).to receive(:update)

      described_class.new.perform(image.id, user.id, {})

      expect(transparent).to be(true)
    end

    it "opts out only on an explicit false" do
      transparent = nil
      allow_any_instance_of(Image).to receive(:create_image_doc) do |_img, _uid, _prompt, **kw|
        transparent = kw[:transparent]
        doc
      end
      allow(doc).to receive(:update)

      described_class.new.perform(image.id, user.id, { "transparent_bg" => false })

      expect(transparent).to be(false)
    end
  end

  describe "content-policy refusals" do
    # AAC vocabulary legitimately includes body parts, medical, and bathroom
    # words that trip the moderator. A refusal on a user's wording shouldn't
    # leave the tile blank.
    it "retries once with the clean house prompt" do
      prompts = []
      call_count = 0
      allow_any_instance_of(Image).to receive(:create_image_doc) do |_img, _uid, prompt, **_kw|
        prompts << prompt
        call_count += 1
        raise "Your request was rejected by the safety system" if call_count == 1

        doc
      end
      allow(doc).to receive(:update)

      described_class.new.perform(image.id, user.id, { "image_prompt" => "a bare chest" })

      expect(prompts.length).to eq(2)
      expect(prompts.first).to include("a bare chest")
      expect(prompts.last).to include("representing 'apple'")
      expect(image.reload.status).not_to eq("failed")
    end

    it "does not retry for unrelated failures" do
      call_count = 0
      allow_any_instance_of(Image).to receive(:create_image_doc) do
        call_count += 1
        raise "insufficient_quota"
      end

      described_class.new.perform(image.id, user.id, { "image_prompt" => "a green apple" })

      expect(call_count).to eq(1)
      expect(image.reload.status).to eq("failed")
    end

    it "gives up rather than looping when the default prompt is what was refused" do
      call_count = 0
      allow_any_instance_of(Image).to receive(:create_image_doc) do
        call_count += 1
        raise "Your request was rejected by the safety system"
      end

      described_class.new.perform(image.id, user.id, {})

      expect(call_count).to eq(1)
      expect(image.reload.status).to eq("failed")
    end
  end

  describe "board image status" do
    let(:board) { FactoryBot.create(:board, user: user) }

    it "marks the tile complete and repoints it at the new doc" do
      board.add_image(image.id)
      board_image = board.board_images.find_by(image_id: image.id)

      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(doc)
      allow(doc).to receive(:update)

      described_class.new.perform(image.id, user.id, { "board_id" => board.id })

      expect(board_image.reload.status).to eq("complete")
      expect(board_image.display_image_url).to eq("https://cdn.example.com/apple.webp")
    end

    it "marks the tile failed when generation errors" do
      board.add_image(image.id)
      board_image = board.board_images.find_by(image_id: image.id)

      allow_any_instance_of(Image).to receive(:create_image_doc).and_raise("boom")

      described_class.new.perform(image.id, user.id, { "board_id" => board.id })

      expect(board_image.reload.status).to eq("failed")
    end
  end
end
