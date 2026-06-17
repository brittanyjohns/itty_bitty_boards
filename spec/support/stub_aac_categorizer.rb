OPENAI_STUB_BODY = { choices: [{ message: { content: '{"part_of_speech":"noun"}' } }] }.to_json.freeze

def register_openai_webmock_stub!
  WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions")
    .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: OPENAI_STUB_BODY)
end

# Global stub for before_all / let_it_be factory calls that trigger
# AacWordCategorizer (via Image#ensure_defaults) before the first example runs.
register_openai_webmock_stub!

RSpec.configure do |config|
  # Re-register before each example group so before_all blocks in later
  # files still have the stub (webmock/rspec clears stubs between groups).
  config.before(:all) do
    register_openai_webmock_stub!
  end

  config.before(:each) do |example|
    register_openai_webmock_stub!

    file = example.metadata[:file_path].to_s
    unless file.include?("aac_word_categorizer")
      allow(AacWordCategorizer).to receive(:categorize).and_return("noun")
    end
  end
end
