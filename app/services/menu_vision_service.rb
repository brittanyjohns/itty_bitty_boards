# app/services/menu_vision_service.rb
require "openai"
require "json"

# Extracts structured menu items directly from a photo of a restaurant menu
# using a vision model via the OpenAI Responses API.
#
# This is the primary extraction path for "menu" boards — the image is sent
# straight to the model, so accuracy no longer depends on in-browser OCR.
class MenuVisionService
  MODEL = ENV.fetch("MENU_VISION_MODEL", "gpt-4.1-mini").freeze

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are an expert at reading photos of restaurant, cafeteria, and cafe menus.
    Your job is to transcribe every food and beverage item shown in the image.
  PROMPT

  USER_PROMPT = <<~PROMPT.freeze
    This image is a restaurant menu.

    Extract EVERY distinct food and beverage item on the menu.

    For each item:
    - name: the exact item name as printed. This is the most important field —
      get it accurate. Use lowercase except for proper nouns.
    - description: the menu's description of the item, if one is printed.
      Omit this field if the menu shows no description.
    - image_description: a short, concrete description of what the dish looks
      like, suitable for generating a picture. Base it on the name and
      description.

    Rules:
    - Only include food and drink items. Ignore prices, headings, section
      titles, addresses, hours, and other non-item text.
    - Do not invent items that are not on the menu.
    - If the image is not a menu or no items are readable, return an empty list.

    Return ONLY JSON with this exact shape:

    {
      "menu_items": [
        {
          "name": "cheeseburger",
          "description": "Served with french fries.",
          "image_description": "A cheeseburger with french fries."
        }
      ]
    }
  PROMPT

  def initialize(openai_client: default_openai_client, logger: default_logger)
    @client = openai_client
    @logger = logger
  end

  # image_url: a publicly reachable https URL (Active Storage / CDN URL).
  #
  # Returns a Hash: { "menu_items" => [ { "name", "description", "image_description" } ] }
  def extract_menu_items(image_url:)
    raise ArgumentError, "image_url required" if image_url.blank?

    @logger.debug "[MenuVisionService] Parsing menu from #{image_url}"

    response = @client.responses.create(
      parameters: {
        model: MODEL,
        input: [
          {
            role: "system",
            content: [
              { type: "input_text", text: SYSTEM_PROMPT },
            ],
          },
          {
            role: "user",
            content: [
              { type: "input_text", text: USER_PROMPT },
              { type: "input_image", image_url: image_url },
            ],
          },
        ],
        text: {
          format: { type: "json_object" },
        },
      },
    )

    raw_json = extract_output_text(response)
    raise "No output_text from Responses API" if raw_json.blank?

    normalize(JSON.parse(raw_json))
  rescue => e
    @logger.error "[MenuVisionService] Error: #{e.class}: #{e.message}"
    raise
  end

  private

  # Handle the Responses API payload shape safely.
  def extract_output_text(response)
    return response["output_text"] if response["output_text"].present?

    content = response.dig("output", 0, "content") || []
    text_chunk = content.find { |c| c["type"] == "output_text" } || content.first
    text_chunk && text_chunk["text"]
  end

  # Keep only well-formed items and the fields the board pipeline consumes.
  def normalize(obj)
    items = Array(obj["menu_items"]).filter_map do |item|
      next unless item.is_a?(Hash)
      name = item["name"].to_s.strip
      next if name.blank?

      result = { "name" => name }
      result["description"] = item["description"].to_s.strip if item["description"].present?
      result["image_description"] = item["image_description"].to_s.strip if item["image_description"].present?
      result
    end

    { "menu_items" => items }
  end

  def default_openai_client
    OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"))
  end

  def default_logger
    defined?(Rails) ? Rails.logger : Logger.new($stdout)
  end
end
