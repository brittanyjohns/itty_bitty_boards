# frozen_string_literal: true

require "rails_helper"
require "rake"

# `boards` has no soft delete, so this task retires a duplicate by clearing
# `predefined` — out of the public library, still published, still resolving
# at /pb/<slug>, and reversible with one column write.
RSpec.describe "public_boards:dedupe", type: :task do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:task) { Rake::Task["public_boards:dedupe"] }
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def run_task(dry_run: false)
    ENV["DRY_RUN"] = dry_run.to_s
    task.reenable
    buffer = StringIO.new
    original = $stdout
    $stdout = buffer
    begin
      task.invoke
    ensure
      $stdout = original
    end
    buffer.string
  ensure
    ENV.delete("DRY_RUN")
  end

  def public_board(name:, slug:, tags: [])
    create(:board, user: admin, name: name, slug: slug, tags: tags,
                   predefined: true, published: true, parent_type: "User")
  end

  it "keeps the board with the most tiles and retires the rest" do
    rich = public_board(name: "numbers", slug: "numbers-1")
    thin = public_board(name: "Numbers", slug: "numbers-2")
    2.times { |n| rich.board_images.create!(image: create(:image, label: "n#{n}")) }

    output = run_task

    expect(output).to include("KEEP    ##{rich.id}")
    expect(output).to include("RETIRE  ##{thin.id}")
    expect(rich.reload.predefined).to be(true)
    expect(thin.reload.predefined).to be(false)
    # Retired, not deleted and not unpublished — /pb/<slug> still resolves.
    expect(thin).to be_persisted
    expect(thin.published).to be(true)
  end

  it "always keeps a myspeak-tagged board, however few tiles it has" do
    tagged = public_board(name: "Feelings", slug: "myspeak-feelings", tags: ["myspeak"])
    other = public_board(name: "feelings", slug: "feelings-old")
    3.times { |n| other.board_images.create!(image: create(:image, label: "f#{n}")) }

    run_task

    expect(tagged.reload.predefined).to be(true)
    expect(other.reload.predefined).to be(false)
  end

  it "writes nothing on a dry run" do
    public_board(name: "I feel", slug: "i-feel-1")
    dupe = public_board(name: "I Feel", slug: "i-feel-2")

    output = run_task(dry_run: true)

    expect(output).to include("RETIRE  ##{dupe.id}")
    expect(output).to include("dry run")
    expect(dupe.reload.predefined).to be(true)
  end

  it "leaves boards with distinct names alone" do
    a = public_board(name: "Letters, Colors, Numbers", slug: "lcn")
    b = public_board(name: "Letters-Numbers-Colors", slug: "lnc")

    expect(run_task).to include("no duplicate names")
    expect(a.reload.predefined).to be(true)
    expect(b.reload.predefined).to be(true)
  end

  it "skips a duplicate that backs a marketplace printable" do
    keeper = public_board(name: "Going to the Zoo", slug: "zoo-1")
    2.times { |n| keeper.board_images.create!(image: create(:image, label: "z#{n}")) }
    sold = public_board(name: "going to the zoo", slug: "zoo-2")

    allow(Boards::MarketplaceProtection)
      .to receive(:protected_board_ids).and_return(Set.new([sold.id]))

    output = run_task

    expect(output).to include("SKIP    ##{sold.id}")
    expect(sold.reload.predefined).to be(true)
  end
end
