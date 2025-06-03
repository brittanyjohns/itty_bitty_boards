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

  def transform_into_json(content_str)
    unless content_str.is_a?(String)
      puts "Content is not a string: #{content_str.class}"
      return {}
    end
    json_str = content_str.gsub(/:([a-zA-z_]+)/, '"\1"') # Convert symbols to strings
    json_str = json_str.gsub("=>", ": ") # Replace hash rockets with colons

    # Now parse the string as JSON
    puts "json_str: #{json_str}"
    begin
      data = JSON.parse(json_str)
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
      result = {}
      result["next_words"] = json_str.split(", ")
      return result
      # Handle invalid JSON here
    end

    # If necessary, convert back to JSON string for output or further processing
    json_output = data.to_json
    puts "json_output: #{json_output}"
    json_output
  end

  def should_generate_image(image, user, tokens_used, total_cost = 0, rerun = false)
    return true if rerun
    existing_doc = image.doc_exists_for_user?(user)
    if existing_doc
      puts "Doc exists for #{image.label}"
      existing_doc.update_user_docs
      existing_doc.update!(current: true)
      return false
    end
    # return false if user.tokens <= tokens_used
    # return false unless token_limit
    # return false if token_limit <= total_cost
    puts "Generating image for #{image.label}, tokens used: #{tokens_used}, total cost: #{total_cost} - User ID: #{user.id}"
    true
  end
end
