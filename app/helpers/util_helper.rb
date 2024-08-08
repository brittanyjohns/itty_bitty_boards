module UtilHelper
  def valid_json?(json)
    JSON.parse(json)
    return true
  rescue JSON::ParserError => e
    return false
  end

  # def transform_into_json(content_str)
  #   json_str = content_str.gsub(/:([a-zA-z_]+)/, '"\1"') # Convert symbols to strings
  #   json_str = json_str.gsub("=>", ": ") # Replace hash rockets with colons

  #   # Now parse the string as JSON
  #   begin
  #     data = JSON.parse(json_str)
  #   rescue JSON::ParserError => e
  #     puts "Error parsing JSON: #{e.message}"
  #     # Handle invalid JSON here
  #   end

  #   # If necessary, convert back to JSON string for output or further processing
  #   json_output = data.to_json
  #   puts "json_output: #{json_output}"
  #   json_output
  # end

  def transform_into_json(content_str)
    puts "Original content_str: #{content_str}"

    # Remove any surrounding brackets or braces that might indicate improper nesting
    content_str = content_str.strip.gsub(/^\{|\}$/, "")
    puts "Cleaned content_str: #{content_str}"

    # Split the string into individual JSON objects
    objects = content_str.split("}\n{")
    puts "Split objects: #{objects}"

    # Ensure we have valid JSON objects
    if objects.empty?
      puts "No valid JSON objects found."
      return nil
    end

    # Add back the braces and commas to form a valid JSON array
    objects.map! { |obj| "{#{obj}}" }
    json_array_str = "[#{objects.join(", ")}]"
    puts "json_array_str: #{json_array_str}"

    # Parse the string as JSON
    begin
      data = JSON.parse(json_array_str)
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
      # Handle invalid JSON here
      return nil
    end

    # If necessary, convert back to JSON string for output or further processing
    json_output = data.to_json
    puts "json_output: #{json_output}"
    json_output
  end

  def should_generate_image(image, user, tokens_used, total_cost = 0)
    existing_doc = image.doc_exists_for_user?(user)
    if existing_doc
      puts "Doc exists for #{image.label}"
      existing_doc.update_user_docs
      existing_doc.update!(current: true)
      return false
    end
    return false if user.tokens <= tokens_used
    return false unless token_limit
    return false if token_limit <= total_cost
    puts "Generating image for #{image.label}, tokens used: #{tokens_used}, total cost: #{total_cost}"
    true
  end
end
