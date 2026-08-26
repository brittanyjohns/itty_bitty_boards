require "rails_helper"

RSpec.describe RegenerateSafetyCardsJob, type: :job do
  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Emma") }
  # A profile whose public slug is a GENERATED one, as a real device-tag
  # profile's is. Set with update_columns because Profile now reserves that
  # SHAPE against user-chosen input (Profile::RANDOM_SLUG_PATTERN, #780), so
  # assigning it through a validated save is refused — the same way
  # spec/requests/api/profiles_spec.rb stands one up.
  let!(:profile) do
    Profile.new(profileable: child, username: "emma", slug: "emma-page").tap do |p|
      p.save!
      p.update_columns(slug: "s-k8x2mf", slug_type: "random")
    end
  end

  before do
    allow(Communicators::GenerateSafetyIdCard).to receive(:call)
    allow(Communicators::GenerateDeviceTag).to receive(:call)
  end

  it "regenerates the device tag forcing a fresh render" do
    described_class.new.perform(profile.id)

    expect(Communicators::GenerateDeviceTag).to have_received(:call).with(profile, regenerate: true)
  end

  # The Safety ID card is no longer offered on Print & share, so refreshing its
  # QR here would spend two headless-Chrome renders on a card nobody is being
  # handed. The generator and its endpoint still exist for anything that asks.
  it "does not rebuild the retired Safety ID card" do
    described_class.new.perform(profile.id)

    expect(Communicators::GenerateSafetyIdCard).not_to have_received(:call)
  end

  it "emails the parent that fresh cards are ready" do
    expect {
      described_class.new.perform(profile.id)
    }.to have_enqueued_mail(CommunicationAccountMailer, :safety_cards_updated)
  end

  it "no-ops for a missing profile" do
    expect {
      described_class.new.perform(-1)
    }.not_to have_enqueued_mail(CommunicationAccountMailer, :safety_cards_updated)
    expect(Communicators::GenerateDeviceTag).not_to have_received(:call)
  end

  it "still regenerates the tag but skips the email when the owner has no email" do
    owner.update_columns(email: "")

    expect {
      described_class.new.perform(profile.id)
    }.not_to have_enqueued_mail(CommunicationAccountMailer, :safety_cards_updated)

    expect(Communicators::GenerateDeviceTag).to have_received(:call).with(profile, regenerate: true)
  end
end
