module UtilHelper
  def valid_json?(json) 
    JSON.parse(json)
    return true
  rescue JSON::ParserError => e
    return false
  end

  def transform_into_json(content_str)
    json_str = content_str.gsub(/:([a-zA-z_]+)/, '"\1"') # Convert symbols to strings
    json_str = json_str.gsub("=>", ": ") # Replace hash rockets with colons

    # Now parse the string as JSON
    begin
      data = JSON.parse(json_str)
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
      # Handle invalid JSON here
    end

    # If necessary, convert back to JSON string for output or further processing
    json_output = data.to_json
    puts "json_output: #{json_output}"
    json_output
  end
end