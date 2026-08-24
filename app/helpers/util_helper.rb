module UtilHelper
  def valid_json?(json)
    if json.blank?
      return false
    end
    if json.is_a?(Hash) || json.is_a?(Array)
      json.to_json
      return true
    end
    JSON.parse(json)
    return true
  rescue JSON::ParserError => e
    return false
  end

  # Best-effort repair of a model reply that is not valid JSON.
  #
  # ALWAYS returns a Hash. It used to return a JSON *String* on its success
  # path, while every caller indexes the result by key — so `words["words"]`
  # was a String#[] substring lookup that answered "words" or nil, never a
  # list. The repair path therefore never actually worked for anyone.
  #
  # `fallback_key` is the key the caller reads. It was hardcoded to
  # "next_words", so the one unparseable-content branch that did build a list
  # filed it under a key only ImageHelper ever looks at.
  def transform_into_json(content_str, fallback_key: "words")
    return content_str if content_str.is_a?(Hash)
    return { fallback_key => content_str } if content_str.is_a?(Array)

    unless content_str.is_a?(String)
      Rails.logger.warn "[transform_into_json] unexpected content: #{content_str.class}"
      return {}
    end

    json_str = content_str.gsub(/:([a-zA-Z_]+)/, '"\1"') # Convert symbols to strings
    json_str = json_str.gsub("=>", ": ")                  # Replace hash rockets with colons

    begin
      parsed = JSON.parse(json_str)
      parsed.is_a?(Hash) ? parsed : { fallback_key => Array(parsed) }
    rescue JSON::ParserError => e
      Rails.logger.warn "[transform_into_json] could not parse response: #{e.message}"
      { fallback_key => json_str.split(",").map(&:strip).reject(&:blank?) }
    end
  end

  def should_generate_image(image, user, tokens_used, total_cost = 0, rerun = false)
    return true # Temporarily always generate
    # return true if rerun
    existing_doc_url = image.display_image_url(user)
    return false if existing_doc_url.present?
    # return false if user.tokens <= tokens_used
    # return false unless token_limit
    # return false if token_limit <= total_cost
    puts "Generating image for #{image.label}, tokens used: #{tokens_used}, total cost: #{total_cost} - User ID: #{user.id}"
    true
  end
end
