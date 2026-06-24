require "rails_helper"

RSpec.describe RegenerateSafetyCardsJob, type: :job do
  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Emma") }
  let!(:profile) { Profile.new(profileable: child, username: "emma", slug: "s-k8x2mf").tap(&:save!) }

  before do
    allow(Communicators::GenerateSafetyIdCard).to receive(:call)
    allow(Communicators::GenerateDeviceTag).to receive(:call)
  end

  it "regenerates both cards forcing a fresh render" do
    described_class.new.perform(profile.id)

    expect(Communicators::GenerateSafetyIdCard).to have_received(:call).with(profile, regenerate: true)
    expect(Communicators::GenerateDeviceTag).to have_received(:call).with(profile, regenerate: true)
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
    expect(Communicators::GenerateSafetyIdCard).not_to have_received(:call)
  end

  it "still regenerates cards but skips the email when the owner has no email" do
    owner.update_columns(email: "")

    expect {
      described_class.new.perform(profile.id)
    }.not_to have_enqueued_mail(CommunicationAccountMailer, :safety_cards_updated)

    expect(Communicators::GenerateSafetyIdCard).to have_received(:call).with(profile, regenerate: true)
  end
end
