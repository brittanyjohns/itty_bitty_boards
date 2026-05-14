require "rails_helper"

RSpec.describe AppEnv do
  describe ".staging?" do
    it "is true when ENV['STAGING'] == 'true'" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("STAGING").and_return("true")
      expect(described_class.staging?).to be(true)
    end

    it "is false when ENV['STAGING'] is unset" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("STAGING").and_return(nil)
      expect(described_class.staging?).to be(false)
    end

    it "is false when ENV['STAGING'] is some other value" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("STAGING").and_return("false")
      expect(described_class.staging?).to be(false)
    end
  end
end
