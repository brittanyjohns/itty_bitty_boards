# frozen_string_literal: true

require "rails_helper"
require "yaml"

# Guards the pairing between the staging env-var manifest and the workflow that
# populates it. Neither file is exercised by any other spec, and a mismatch is
# invisible until someone dispatches the sync — which happens rarely enough that
# the last one succeeded 2026-05-13 and the next one, 2026-09-12, aborted on 15
# MAILCHIMP_JOURNEY* names listed as required with no secrets behind them. Four
# months of staging env changes could not land and nothing said so.
RSpec.describe "staging env var manifest" do
  manifest_path = Rails.root.join("script/hatchbox/staging_env_vars.yml")
  workflow_path = Rails.root.join(".github/workflows/staging-sync-env.yml")

  let(:manifest) { YAML.load_file(manifest_path) }
  let(:names)    { manifest.fetch("vars") }
  let(:optional) { Array(manifest["optional"]) }
  let(:workflow_env) do
    YAML.load_file(workflow_path).dig("jobs", "sync", "steps").last.fetch("env")
  end

  it "wires every manifest name up in the workflow" do
    # sync_env_vars.rb reads values from ENV, which the workflow populates. A
    # name here with no line there can never receive a value, so it either
    # aborts the sync or is silently skipped forever.
    expect(names.reject { |n| workflow_env.key?(n) }).to be_empty
  end

  it "has no optional entry missing from vars" do
    # `optional` only softens a name that is actually in `vars`; anything else
    # is a dead entry that reads as a guarantee and provides none.
    expect(optional.reject { |n| names.include?(n) }).to be_empty
  end

  it "keeps the Mailchimp journey triggers optional" do
    # staging-sync-env.yml states that leaving MAILCHIMP_JOURNEYS_ENABLED unset
    # is how journeys stay off on staging. Unset is therefore a SUPPORTED state,
    # and a supported-empty var must be optional or it aborts the whole sync.
    journeys = names.grep(/\AMAILCHIMP_JOURNEY/)

    expect(journeys).not_to be_empty
    expect(journeys - optional).to be_empty
  end

  it "does not abort when every optional var is empty" do
    # The exact check from script/hatchbox/sync_env_vars.rb. Worst realistic
    # case: every optional secret unset, every required one present.
    env = names.to_h { |n| [n, optional.include?(n) ? "" : "value"] }

    missing = names.select { |n| env[n].to_s.empty? && !optional.include?(n) }

    expect(missing).to be_empty
  end
end
