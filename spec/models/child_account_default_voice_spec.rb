require "rails_helper"

# The communicator form collects `age_band` and stores it; nothing downstream
# read it, so every communicator — a 17-year-old included — was defaulted to a
# voice whose own description said it was for kids.
RSpec.describe ChildAccount, "default voice", type: :model do
  let(:user) { create(:user) }

  def communicator_with(age_band)
    create(:child_account, user: user, name: "Jordan", details: { "age_band" => age_band }.compact)
  end

  it "keeps the kid voice for the youngest bands" do
    expect(communicator_with("4-6").voice).to eq("polly:kevin")
    expect(communicator_with("7-10").voice).to eq("polly:kevin")
  end

  it "does not hand an 11+ communicator a voice tagged kid" do
    %w[11-14 15-18 adult].each do |band|
      voice = VoiceService.get_voice(communicator_with(band).voice)
      expect(voice[:tags]).not_to include("kid"), "#{band} resolved to #{voice[:value]}"
    end
  end

  it "falls back to the app default when no band was ever recorded" do
    expect(communicator_with(nil).voice).to eq(VoiceService::DEFAULT_VOICE)
  end

  # The default only ever fills an absence. A caller who deliberately picked
  # Kevin for a 17-year-old keeps Kevin.
  it "never overrides a voice somebody chose" do
    communicator = communicator_with("15-18")
    communicator.voice = "polly:kevin"

    expect(communicator.reload.voice).to eq("polly:kevin")
  end

  it "reflects a band set after the record already existed" do
    communicator = communicator_with(nil)
    expect(communicator.voice).to eq("polly:kevin")

    communicator.update!(details: { "age_band" => "adult" })

    expect(VoiceService.get_voice(communicator.reload.voice)[:tags]).not_to include("kid")
  end

  # voice_settings seeds the whole blob, not just the name — a reader that goes
  # through it (language, speed) must get the same answer as `voice`.
  it "seeds voice_settings with the band's default" do
    communicator = communicator_with("adult")
    expect(communicator.voice_settings["name"]).to eq(communicator.voice)
  end
end
