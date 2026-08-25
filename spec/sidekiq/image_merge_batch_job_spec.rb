require "rails_helper"

RSpec.describe ImageMergeBatchJob do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def library_image(label)
    create(:image, label: label, user_id: nil, is_private: false)
  end

  def planned_batch(status: "planned")
    2.times { library_image("wagon") }
    2.times { library_image("kite") }
    plan = Images::DuplicateScanner.call
    ImageMergeBatch.create!(status: status, plan: { "groups" => plan["groups"] }, report: plan["report"])
  end

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before { ImageMergeJob.clear }

  it "enqueues one merge job per group and flips the batch to running" do
    batch = planned_batch

    described_class.new.perform(batch.id)

    expect(ImageMergeJob.jobs.size).to eq(batch.groups.size)
    expect(ImageMergeJob.jobs.map { |j| j["args"] }).to match_array(
      batch.groups.each_index.map { |i| [batch.id, i] }
    )
    expect(batch.reload).to be_running
  end

  it "puts the work on the lowest-priority queue so it cannot starve tile or audio work" do
    described_class.new.perform(planned_batch.id)

    expect(ImageMergeJob.jobs.map { |j| j["queue"] }.uniq).to eq(["maintenance"])
  end

  it "resumes a paused batch without re-enqueuing groups that already ran" do
    batch = planned_batch
    ImageMerge.create!(image_merge_batch_id: batch.id, group_index: 0, status: "merged")
    batch.update!(status: "paused")

    described_class.new.perform(batch.id)

    expect(ImageMergeJob.jobs.map { |j| j["args"].last }).not_to include(0)
    expect(ImageMergeJob.jobs.size).to eq(batch.groups.size - 1)
  end

  it "refuses to start a batch that is already complete" do
    batch = planned_batch
    batch.update!(status: "complete")

    described_class.new.perform(batch.id)

    expect(ImageMergeJob.jobs).to be_empty
  end

  it "completes immediately when the plan is empty" do
    batch = ImageMergeBatch.create!(status: "planned", plan: { "groups" => [] })

    described_class.new.perform(batch.id)

    expect(batch.reload).to be_complete
    expect(ImageMergeJob.jobs).to be_empty
  end
end
