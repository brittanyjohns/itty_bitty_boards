require "rails_helper"

RSpec.describe DisposableEmailDomains do
  it "flags a known disposable domain" do
    expect(described_class.disposable?("someone@mailinator.com")).to be(true)
  end

  it "is case-insensitive" do
    expect(described_class.disposable?("Someone@MAILINATOR.com")).to be(true)
  end

  it "allows ordinary providers" do
    expect(described_class.disposable?("parent@gmail.com")).to be(false)
    expect(described_class.disposable?("slp@schooldistrict.org")).to be(false)
  end

  it "is nil- and garbage-safe" do
    expect(described_class.disposable?(nil)).to be(false)
    expect(described_class.disposable?("")).to be(false)
    expect(described_class.disposable?("no-at-sign")).to be(false)
  end

  it "matches only the domain, never the local part" do
    expect(described_class.disposable?("mailinator.com@gmail.com")).to be(false)
  end
end
