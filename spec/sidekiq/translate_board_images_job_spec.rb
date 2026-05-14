require "rails_helper"

RSpec.describe TranslateBoardImagesJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user, language: "en") }
  let!(:image_a) { FactoryBot.create(:image, label: "hello") }
  let!(:image_b) { FactoryBot.create(:image, label: "world") }
  let!(:bi_a) { FactoryBot.create(:board_image, board: board, image: image_a) }
  let!(:bi_b) { FactoryBot.create(:board_image, board: board, image: image_b) }

  it "skips when board is missing" do
    expect(TranslateImageJob).not_to receive(:perform_async)
    described_class.new.perform(0, "es")
  end

  it "skips when language is blank or 'en'" do
    expect(TranslateImageJob).not_to receive(:perform_async)
    described_class.new.perform(board.id, "en")
    described_class.new.perform(board.id, "")
  end

  it "skips when language is unsupported" do
    expect(TranslateImageJob).not_to receive(:perform_async)
    described_class.new.perform(board.id, "xx")
  end

  it "queues a TranslateImageJob for each image missing the translation" do
    expect(TranslateImageJob).to receive(:perform_async).with(image_a.id, "es")
    expect(TranslateImageJob).to receive(:perform_async).with(image_b.id, "es")
    described_class.new.perform(board.id, "es")
  end

  it "skips images that already have the translation" do
    image_a.update!(language_settings: { "es" => { "label" => "hola" } })
    expect(TranslateImageJob).not_to receive(:perform_async).with(image_a.id, "es")
    expect(TranslateImageJob).to receive(:perform_async).with(image_b.id, "es")
    described_class.new.perform(board.id, "es")
  end
end

RSpec.describe Board, type: :model do
  describe "#schedule_translations_for" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    before do
      cache = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(cache)
    end

    it "does nothing for English" do
      expect(TranslateBoardImagesJob).not_to receive(:perform_async)
      board.schedule_translations_for("en")
    end

    it "does nothing for unsupported languages" do
      expect(TranslateBoardImagesJob).not_to receive(:perform_async)
      board.schedule_translations_for("xx")
    end

    it "enqueues the job for a supported language" do
      expect(TranslateBoardImagesJob).to receive(:perform_async).with(board.id, "es")
      board.schedule_translations_for("es")
    end

    it "does not enqueue again within the cache window" do
      expect(TranslateBoardImagesJob).to receive(:perform_async).with(board.id, "es").once
      board.schedule_translations_for("es")
      board.schedule_translations_for("es")
    end
  end
end
