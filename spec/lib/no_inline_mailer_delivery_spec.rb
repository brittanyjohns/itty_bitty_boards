require "rails_helper"

# Regression coverage for the 2026-05-30 production outage (see issue #207):
# inline `deliver_now` calls in request and lifecycle paths can wedge puma
# threads when SMTP stalls. Phase 2 of #207 moved every such call to
# `deliver_later`. This guard fails the suite if a `deliver_now` reappears
# in any non-Sidekiq app path.
#
# Allowed exception: mailer sends that already run inside a Sidekiq job —
# they're off the request thread, so blocking on SMTP is fine.
RSpec.describe "inline mailer delivery regression guard" do
  ALLOWED_DELIVER_NOW_PATHS = [
    "app/sidekiq/",
  ].freeze

  it "has no `deliver_now` calls outside Sidekiq jobs" do
    offenders = []

    Dir.glob(Rails.root.join("app/**/*.rb")).each do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if ALLOWED_DELIVER_NOW_PATHS.any? { |allowed| rel.start_with?(allowed) }

      File.foreach(path).with_index(1) do |line, lineno|
        # Skip comment-only lines.
        next if line.strip.start_with?("#")
        offenders << "#{rel}:#{lineno}: #{line.strip}" if line.include?("deliver_now")
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Found inline `deliver_now` calls outside Sidekiq. Use `deliver_later` so
      a stalled SMTP session can't wedge a puma thread (see issue #207):

      #{offenders.join("\n")}
    MSG
  end
end
