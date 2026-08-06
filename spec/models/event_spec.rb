# == Schema Information
#
# Table name: events
#
#  id                 :bigint           not null, primary key
#  name               :string
#  slug               :string
#  date               :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  promo_code         :string
#  promo_code_details :string
#
require 'rails_helper'

RSpec.describe Event, type: :model do
  describe "#set_slug" do
    it "auto-derives the slug from name when slug is left blank" do
      event = Event.new(name: "Spring Giveaway 2026!")

      expect(event.save).to be true
      expect(event.slug).to eq("spring-giveaway-2026")
    end

    it "parameterizes an explicitly-provided slug" do
      event = Event.new(name: "Spring Giveaway", slug: "Custom Slug")

      expect(event.save).to be true
      expect(event.slug).to eq("custom-slug")
    end

    it "is invalid without a name to derive a slug from" do
      event = Event.new(name: "")

      expect(event.save).to be false
      expect(event.errors[:slug]).to be_present
    end
  end
end
