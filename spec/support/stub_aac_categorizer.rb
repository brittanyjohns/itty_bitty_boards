OPENAI_STUB_BODY = { choices: [{ message: { content: '{"part_of_speech":"noun"}' } }] }.to_json.freeze

# Global stub survives for before_all / let_it_be factory calls that trigger
# AacWordCategorizer (via Image#ensure_defaults) before the first example runs.
WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions")
  .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: OPENAI_STUB_BODY)

RSpec.configure do |config|
  config.before(:each) do |example|
    # Re-register after webmock/rspec clears stubs between examples
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: OPENAI_STUB_BODY)

    file = example.metadata[:file_path].to_s
    unless file.include?("aac_word_categorizer")
      allow(AacWordCategorizer).to receive(:categorize).and_return("noun")
    end
  end
end
