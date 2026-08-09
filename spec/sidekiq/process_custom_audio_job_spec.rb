require "rails_helper"

# Recorded clips arrive as whatever MediaRecorder produced — audio/webm on
# Chrome, which Safari on iPad won't play. This job converts them to mp3 and
# repoints the tile. It must fail soft: an unconverted clip is worse than
# nothing only if we've also destroyed the original.
RSpec.describe ProcessCustomAudioJob do
  let(:user)        { create(:user) }
  let(:board)       { create(:board, user: user, voice: "polly:kevin") }
  let(:image)       { create(:image, label: "juice") }
  let(:board_image) { create(:board_image, board: board, image: image) }

  # audio_url is set to a literal and only ever compared to that literal: the
  # Disk service signs its URLs, so re-generating one for the same blob gives a
  # different string every call and an equality check against a fresh one
  # proves nothing.
  def attach_recording(content_type: "audio/webm", filename: "juice-custom-010125000000-abc123.webm")
    board_image.audio_files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
      filename: filename, content_type: content_type, identify: false,
    )
    board_image.reload.audio_files_attachments.order(:id).last
  end

  before { AudioTranscoder.reset_availability! }
  after  { AudioTranscoder.reset_availability! }

  it "replaces the recording with an mp3 and repoints the tile" do
    attachment = attach_recording
    webm_url = "https://cdn.example/juice-custom.webm"
    board_image.set_custom_audio!(webm_url)
    allow(AudioTranscoder).to receive(:available?).and_return(true)
    allow(AudioTranscoder).to receive(:transcode) do |_input, output, **|
      File.binwrite(output, File.binread(Rails.root.join("spec/fixtures/files/sample.mp3")))
      true
    end

    described_class.new.perform(board_image.id, attachment.id)

    board_image.reload
    filenames = board_image.audio_files.map { |af| af.blob.filename.to_s }
    expect(filenames).to include("juice-custom-010125000000-abc123.mp3")
    expect(board_image.using_custom_audio?).to be(true)
    expect(board_image.audio_url).to be_present
    expect(board_image.audio_url).not_to eq(webm_url)
  end

  it "leaves an already-playable clip alone" do
    attachment = attach_recording(content_type: "audio/mpeg", filename: "juice-custom-1.mp3")
    expect(AudioTranscoder).not_to receive(:transcode)

    described_class.new.perform(board_image.id, attachment.id)

    expect(board_image.reload.audio_files.count).to eq(1)
  end

  it "keeps the original attached when ffmpeg is unavailable" do
    attachment = attach_recording
    allow(AudioTranscoder).to receive(:available?).and_return(false)

    described_class.new.perform(board_image.id, attachment.id)

    expect(board_image.reload.audio_files.count).to eq(1)
    expect(board_image.audio_files.first.blob.filename.to_s).to end_with(".webm")
  end

  it "keeps the original attached when the transcode fails" do
    attachment = attach_recording
    allow(AudioTranscoder).to receive(:available?).and_return(true)
    allow(AudioTranscoder).to receive(:transcode).and_return(false)

    described_class.new.perform(board_image.id, attachment.id)

    expect(board_image.reload.audio_files.count).to eq(1)
  end

  it "does not repoint a tile the user has since moved to another clip" do
    attachment = attach_recording
    board_image.set_voice_audio!("https://cdn.example/other.mp3", "polly:kevin")
    allow(AudioTranscoder).to receive(:available?).and_return(true)
    allow(AudioTranscoder).to receive(:transcode) do |_input, output, **|
      File.binwrite(output, File.binread(Rails.root.join("spec/fixtures/files/sample.mp3")))
      true
    end

    described_class.new.perform(board_image.id, attachment.id)

    expect(board_image.reload.audio_url).to eq("https://cdn.example/other.mp3")
  end

  it "does not repoint a tile the user has re-recorded since" do
    attachment = attach_recording
    board_image.set_custom_audio!("https://cdn.example/first.webm")
    attach_recording(filename: "juice-custom-010125000001-def456.webm")
    newer_url = "https://cdn.example/second.webm"
    board_image.set_custom_audio!(newer_url)
    allow(AudioTranscoder).to receive(:available?).and_return(true)
    allow(AudioTranscoder).to receive(:transcode) do |_input, output, **|
      File.binwrite(output, File.binread(Rails.root.join("spec/fixtures/files/sample.mp3")))
      true
    end

    described_class.new.perform(board_image.id, attachment.id)

    expect(board_image.reload.audio_url).to eq(newer_url)
  end

  it "does nothing for an attachment that is not on this tile" do
    expect { described_class.new.perform(board_image.id, 0) }.not_to raise_error
  end
end
