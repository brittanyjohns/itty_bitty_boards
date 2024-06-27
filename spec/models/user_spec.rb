require "rails_helper"

RSpec.describe User, type: :model do
  context "validation" do
    subject(:user) { FactoryBot.build(:user) }
    it "is invalid without a email" do
      user.email = nil
      expect(user.save).to be_falsey
    end

    it "is valid with name and email" do
      user.name = "Some name"
      user.email = "email@test.com"
      expect(user.save).to be_truthy
    end
  end
end
