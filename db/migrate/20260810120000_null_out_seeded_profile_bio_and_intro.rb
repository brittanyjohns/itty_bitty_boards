# Clears the instructional copy this app used to write into `profiles.bio` and
# `profiles.intro` at creation.
#
# Both columns are PUBLIC — the MySpeak page (`/my/:slug`) prints the bio as
# "About me" and speaks the intro aloud on "Hear my intro" — so every profile
# that had never been personalized published "Write a short bio about
# yourself…" to visitors in the communicator's own voice. The seeding is gone
# (Profile#set_defaults, .create_for_user, .generate_with_username,
# .create_placeholders); this clears the rows already carrying it.
#
# The strings are inlined rather than read from Profile::SEEDED_TEXT on
# purpose. A migration has to keep running years from now, after the constant
# has drifted or been deleted — it records what the data looked like at this
# point in history, and must not change meaning when the model does.
#
# Matched with `=` on the BTRIM'd value, never LIKE or a substring test: a real
# bio that happens to quote the phrase belongs to whoever wrote it and must
# survive untouched.
#
# Raw SQL rather than find_each: this is a data correction across every profile
# row, and Profile's validation + before_save chain (slug format, kind
# inference, slug_changed_at) has no business firing for it. Blanking these
# columns cannot invalidate a row — neither has a presence validation.
class NullOutSeededProfileBioAndIntro < ActiveRecord::Migration[8.0]
  SEEDED_BIOS = [
    "Write a short bio about yourself. This will help others understand who you are and what you do.",
    "This is a placeholder profile waiting to be claimed. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
    "This is a placeholder profile. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
  ].freeze

  SEEDED_INTROS = [
    "Welcome to MySpeak! Personalize your page by adding a short introduction about yourself.",
    "Welcome to MySpeak! Personalize your page by adding a short introduction about yourself here.",
    "Welcome to MySpeak! Let's get started.",
  ].freeze

  def up
    say_with_time "Clearing seeded profiles.bio" do
      execute(<<~SQL.squish)
        UPDATE profiles
           SET bio = NULL
         WHERE BTRIM(bio) IN (#{quoted_list(SEEDED_BIOS)})
      SQL
    end

    say_with_time "Clearing seeded profiles.intro" do
      execute(<<~SQL.squish)
        UPDATE profiles
           SET intro = NULL
         WHERE BTRIM(intro) IN (#{quoted_list(SEEDED_INTROS)})
      SQL
    end
  end

  # Irreversible on purpose. Re-seeding the copy would republish the exact text
  # this migration exists to take off public pages, and there is no record of
  # which rows held it — a blank bio after this runs is indistinguishable from
  # one that was always blank. Rolling back means leaving the columns nil.
  def down
    say "No-op: seeded bio/intro copy is not restored."
  end

  private

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end
