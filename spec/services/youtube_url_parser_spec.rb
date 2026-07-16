require "rails_helper"

RSpec.describe YoutubeUrlParser do
  describe ".video_id" do
    valid_cases = {
      "standard watch URL" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "watch URL with extra params" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&si=abc",
      "short youtu.be URL" => "https://youtu.be/dQw4w9WgXcQ",
      "youtu.be with query cruft" => "https://youtu.be/dQw4w9WgXcQ?si=xyz123",
      "embed URL" => "https://www.youtube.com/embed/dQw4w9WgXcQ",
      "nocookie embed URL" => "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
      "shorts URL" => "https://www.youtube.com/shorts/dQw4w9WgXcQ",
      "mobile host" => "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
      "no scheme" => "youtube.com/watch?v=dQw4w9WgXcQ",
      "http scheme" => "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
    }

    valid_cases.each do |desc, url|
      it "extracts the id from a #{desc}" do
        expect(described_class.video_id(url)).to eq("dQw4w9WgXcQ")
      end
    end

    invalid_cases = {
      "nil" => nil,
      "blank" => "",
      "non-YouTube host" => "https://vimeo.com/12345",
      "lookalike host" => "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
      "javascript scheme" => "javascript:alert(1)",
      "bare id (not a URL)" => "dQw4w9WgXcQ",
      "wrong id length" => "https://www.youtube.com/watch?v=short",
      "id with invalid chars" => "https://www.youtube.com/watch?v=dQw4w9WgXc!",
      "channel URL (no video)" => "https://www.youtube.com/@somechannel",
      "malformed URI" => "https://youtube.com/watch?v=%%%",
    }

    invalid_cases.each do |desc, url|
      it "rejects #{desc}" do
        expect(described_class.video_id(url)).to be_nil
      end
    end
  end

  describe ".embed_url" do
    it "builds the privacy-enhanced nocookie embed URL" do
      expect(described_class.embed_url("dQw4w9WgXcQ"))
        .to eq("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    end
  end
end
