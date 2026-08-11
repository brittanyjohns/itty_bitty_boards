require "rails_helper"
require "rake"

RSpec.describe "labels rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  def run(name, **env)
    env.each { |k, v| ENV[k.to_s] = v.to_s }
    task = Rake::Task["labels:#{name}"]
    task.reenable
    task.invoke
  ensure
    env.each_key { |k| ENV.delete(k.to_s) }
  end

  # display_label is written directly: these rows stand in for tiles created
  # BEFORE the normalizer fix, which is the only thing the backfill exists for.
  def tile(display_label, predictive_board_id: nil, part_of_speech: "noun")
    bi = create(:board_image, board: board, part_of_speech: part_of_speech,
                              predictive_board_id: predictive_board_id,
                              image: create(:image, label: display_label.downcase, user_id: user.id))
    bi.update_columns(display_label: display_label)
    bi
  end

  describe "labels:fold_casing_report" do
    it "writes nothing" do
      stuck = tile("Fun")

      expect { run("fold_casing_report") }.to output(/DRY RUN/).to_stdout
      expect(stuck.reload.display_label).to eq("Fun")
    end
  end

  describe "labels:fold_casing" do
    it "is a dry run unless APPLY=1 is passed" do
      stuck = tile("Fun")

      expect { run("fold_casing") }.to output(/DRY RUN/).to_stdout
      expect(stuck.reload.display_label).to eq("Fun")
    end

    it "folds a stuck capital down when applied" do
      stuck = tile("Fun")
      phrase = tile("All Done")

      run("fold_casing", APPLY: 1)

      expect(stuck.reload.display_label).to eq("fun")
      expect(phrase.reload.display_label).to eq("all done")
    end

    it "leaves deliberate casing and the standalone pronoun alone" do
      brand = tile("iPad")
      acronym = tile("TV")
      pronoun = tile("I", part_of_speech: "pronoun")

      run("fold_casing", APPLY: 1)

      expect(brand.reload.display_label).to eq("iPad")
      expect(acronym.reload.display_label).to eq("TV")
      expect(pronoun.reload.display_label).to eq("I")
    end

    # A category tile's capital is authored on purpose, and predictive_board_id
    # can't tell a curated folder from a predictive word tile — so linked tiles
    # are left alone unless explicitly asked for.
    it "skips a linked tile by default and folds it with INCLUDE_LINKED" do
      folder = tile("Food", predictive_board_id: create(:board, user: user).id)

      run("fold_casing", APPLY: 1)
      expect(folder.reload.display_label).to eq("Food")

      run("fold_casing", APPLY: 1, INCLUDE_LINKED: 1)
      expect(folder.reload.display_label).to eq("food")
    end

    it "restricts to folding down when ONLY=down" do
      stuck = tile("Fun")
      lower_i = tile("i", part_of_speech: "pronoun")
      lower_i.update_columns(display_label: "i")

      run("fold_casing", APPLY: 1, ONLY: "down")

      expect(stuck.reload.display_label).to eq("fun")
      expect(lower_i.reload.display_label).to eq("i")
    end

    it "confines itself to one board when BOARD_ID is given" do
      other_board = create(:board, user: user)
      mine = tile("Fun")
      theirs = create(:board_image, board: other_board,
                                    image: create(:image, label: "swing", user_id: user.id))
      theirs.update_columns(display_label: "Swing")

      run("fold_casing", APPLY: 1, BOARD_ID: board.id)

      expect(mine.reload.display_label).to eq("fun")
      expect(theirs.reload.display_label).to eq("Swing")
    end

    it "never changes what a tile says, only how it is cased" do
      stuck = tile("Eat Breakfast")

      run("fold_casing", APPLY: 1)

      expect(stuck.reload.display_label.downcase).to eq("eat breakfast")
    end

    # The jsonb is what BoardImage#set_labels reads FIRST, so a clean
    # display_label column with a stuck capital in language_settings is the
    # exact state that kept re-inheriting capitals onto every new board.
    context "language_settings" do
      def image_with_translations(settings, label: "want", part_of_speech: "verb")
        create(:image, label: label, user_id: user.id, part_of_speech: part_of_speech,
                       language_settings: settings)
      end

      it "folds a stuck capital out of the English entry" do
        image = image_with_translations({ "en" => { "label" => "want", "display_label" => "Want" } })

        run("fold_casing", APPLY: 1)

        expect(image.reload.language_settings["en"]["display_label"]).to eq("want")
      end

      it "leaves a genuine non-English translation verbatim" do
        image = image_with_translations({
          "en" => { "label" => "want", "display_label" => "Want" },
          "es" => { "label" => "quiero", "display_label" => "Quiero" },
        })

        run("fold_casing", APPLY: 1)

        expect(image.reload.language_settings["es"]["display_label"]).to eq("Quiero")
      end

      it "leaves the matching label key untouched" do
        image = image_with_translations({ "en" => { "label" => "want", "display_label" => "Want" } })

        run("fold_casing", APPLY: 1)

        expect(image.reload.language_settings["en"]["label"]).to eq("want")
      end

      it "folds the jsonb even when the display_label column is already clean" do
        image = image_with_translations(
          { "en" => { "label" => "all done", "display_label" => "All Done" } },
          label: "all done", part_of_speech: "social",
        )
        image.update_columns(display_label: "all done")

        run("fold_casing", APPLY: 1)

        expect(image.reload.language_settings["en"]["display_label"]).to eq("all done")
      end

      it "writes nothing on a dry run" do
        image = image_with_translations({ "en" => { "label" => "want", "display_label" => "Want" } })

        run("fold_casing")

        expect(image.reload.language_settings["en"]["display_label"]).to eq("Want")
      end

      it "is skipped entirely by IMAGES=0" do
        image = image_with_translations({ "en" => { "label" => "want", "display_label" => "Want" } })

        run("fold_casing", APPLY: 1, IMAGES: 0)

        expect(image.reload.language_settings["en"]["display_label"]).to eq("Want")
      end
    end
  end
end
