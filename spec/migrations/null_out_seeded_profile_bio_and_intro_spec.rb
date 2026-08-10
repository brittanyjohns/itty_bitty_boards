require "rails_helper"
require Rails.root.join("db/migrate/20260810120000_null_out_seeded_profile_bio_and_intro.rb")

# The rows this migration exists for were written when Profile seeded bio and
# intro on create. Nothing writes that copy any more, so the specs put it back
# with update_column to reproduce the historical state.
RSpec.describe NullOutSeededProfileBioAndIntro do
  let(:migration) { described_class.new }
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }

  let(:seeded_bio) do
    "Write a short bio about yourself. This will help others understand who you are and what you do."
  end
  let(:seeded_intro) do
    "Welcome to MySpeak! Personalize your page by adding a short introduction about yourself."
  end

  def profile_with(slug:, bio: nil, intro: nil)
    profile = Profile.create!(profileable: child, username: slug, slug: slug)
    profile.update_columns(bio: bio, intro: intro)
    profile
  end

  before { migration.verbose = false }

  it "clears a seeded bio and intro" do
    seeded = profile_with(slug: "quiet-fox", bio: seeded_bio, intro: seeded_intro)

    migration.up

    expect(seeded.reload.bio).to be_nil
    expect(seeded.reload.intro).to be_nil
  end

  it "clears the placeholder variants too" do
    placeholder = profile_with(
      slug: "loud-fox",
      bio: "This is a placeholder profile waiting to be claimed. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
      intro: "Welcome to MySpeak! Personalize your page by adding a short introduction about yourself here.",
    )

    migration.up

    expect(placeholder.reload.bio).to be_nil
    expect(placeholder.reload.intro).to be_nil
  end

  # lib/tasks/accounts.rake carried its own near-copy of the placeholder
  # wording, so these rows exist too and claim! would have carried them onto a
  # real page.
  it "clears the accounts.rake placeholder wording" do
    placeholder = profile_with(
      slug: "pale-fox",
      bio: "This is a placeholder profile. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
      intro: "Welcome to MySpeak! Let's get started.",
    )

    migration.up

    expect(placeholder.reload.bio).to be_nil
    expect(placeholder.reload.intro).to be_nil
  end

  it "matches despite surrounding whitespace" do
    padded = profile_with(slug: "sly-fox", bio: "  #{seeded_bio}  ", intro: " #{seeded_intro}")

    migration.up

    expect(padded.reload.bio).to be_nil
    expect(padded.reload.intro).to be_nil
  end

  # The whole point of matching exactly rather than with LIKE — these belong to
  # the people who wrote them.
  it "leaves a real bio and intro untouched" do
    real = profile_with(slug: "red-fox", bio: "I love trains.", intro: "Hi, I'm Sky.")

    migration.up

    expect(real.reload.bio).to eq("I love trains.")
    expect(real.reload.intro).to eq("Hi, I'm Sky.")
  end

  it "leaves a real bio that quotes the seeded copy untouched" do
    quoting = profile_with(
      slug: "grey-fox",
      bio: "The app said \"#{seeded_bio}\" so here goes: I love trains.",
      intro: nil,
    )

    migration.up

    expect(quoting.reload.bio).to include("I love trains.")
  end

  it "is idempotent" do
    seeded = profile_with(slug: "swift-fox", bio: seeded_bio, intro: seeded_intro)

    migration.up
    expect { migration.up }.not_to raise_error

    expect(seeded.reload.bio).to be_nil
  end
end
