# app/services/board_screenshot_vision_service.rb
require "openai"
require "base64"
require "json"

class BoardScreenshotVisionService
  MODEL = ENV.fetch("BOARD_SCREENSHOT_VISION_MODEL", "gpt-4.1-mini").freeze

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are an expert at analyzing screenshots of communication boards used in AAC
    (augmentative and alternative communication) apps.

    Your ONLY job is to detect the grid of buttons and describe every cell in the grid.
  PROMPT

  USER_PROMPT = <<~PROMPT
    Analyze this AAC board screenshot.

    1. Determine the full button grid:
        - Count how many rows of buttons.
        - Count how many columns of buttons.
        - The grid should include columns even if some cells in that column are blank.

    2. For EVERY grid position (row, col), output a cell object:
        - row: zero-based row index
        - col: zero-based column index
        - label_raw: the exact text shown on the button, or null if the cell is blank
        - label_norm: lowercase normalized version of the label (no punctuation), or null
        - confidence: 0.0-1.0 confidence
        - bbox: [x, y, width, height]
        - bg_color: **one of the following strings**, whichever is closest to the actual BACKGROUND fill color of the button:
            #{Image::POSSIBLE_BG_COLORS.join(",")}

        Ignore images, icons, borders, text, shadows - choose based only on the dominant BACKGROUND fill color.
        If no color is close enough, choose "white".

    IMPORTANT:
    - rows * cols MUST equal the total number of cell objects.
    - Even if a cell is blank, still include it with label_raw = null and label_norm = null.
    - Do NOT skip columns even if some are blank.

    Return ONLY JSON with this exact shape:

    {
        "rows": <integer>,
        "cols": <integer>,
        "cells": [
        {
            "row": <integer>,
            "col": <integer>,
            "label_raw": <string or null>,
            "label_norm": <string or null>,
            "confidence": <number>,
            "bbox": [<number>, <number>, <number>, <number>],
            "bg_color": <string>
        }
        ]
    }
  PROMPT

  def initialize(openai_client: default_openai_client, logger: default_logger)
    @client = openai_client
    @logger = logger
  end

  # image_path: path to a local, preprocessed image file (jpg/png)
  # Returns:
  # {
  #   rows: Integer,
  #   cols: Integer,
  #   confidence_avg: Float,
  #   cells: [
  #     { row:, col:, label_raw:, label_norm:, confidence:, bbox: [x,y,w,h] }
  #   ]
  # }
  def parse_board(image_path:)
    raise ArgumentError, "image_path required" if image_path.blank?

    @logger.debug "[BoardScreenshotVisionService] Parsing board from #{image_path}"

    data_url = encode_image_as_data_url(image_path)

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
              {
                type: "input_image",
                image_url: data_url, # MUST be data URL or public https URL
              },
            ],
          },
        ],
        # JSON mode for Responses API
        text: {
          format: { type: "json_object" },
        },
      },
    )

    @logger.debug "[BoardScreenshotVisionService] Raw responses payload: #{response.inspect}"

    raw_json = extract_output_text(response)
    raise "No output_text from Responses API" if raw_json.blank?

    obj = JSON.parse(raw_json)
    normalize(obj)
  rescue => e
    @logger.error "[BoardScreenshotVisionService] Error: #{e.class}: #{e.message}"
    raise
  end

  private

  # Turn a local file into data:image/...;base64,....
  def encode_image_as_data_url(image_path)
    bytes = File.binread(image_path)
    base64 = Base64.strict_encode64(bytes)

    ext = File.extname(image_path).downcase
    mime = case ext
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".png" then "image/png"
      else "image/png"
      end

    "data:#{mime};base64,#{base64}"
  end

  # Handle Responses API structure safely
  def extract_output_text(response)
    # Some client versions may expose a top-level "output_text"
    return response["output_text"] if response["output_text"].present?

    content = response.dig("output", 0, "content") || []
    text_chunk = content.find { |c| c["type"] == "output_text" } || content.first
    text_chunk && text_chunk["text"]
  end

  # Ensure we:
  # - use label_raw / label_norm
  # - fill in EVERY (row, col) even if the model skips some
  def normalize(obj)
    rows = (obj["rows"] || 6).to_i
    cols = (obj["cols"] || 8).to_i

    cells = (obj["cells"] || []).map do |c|
      label_raw = c["label_raw"]
      label_norm = c["label_norm"]
      label = label_norm.presence || label_raw.to_s

      {
        row: c["row"].to_i,
        col: c["col"].to_i,
        label_raw: label_raw,
        label_norm: label_norm,
        label: label,
        confidence: (c["confidence"] || 0.0).to_f,
        bbox: Array(c["bbox"] || [0, 0, 0, 0]).map(&:to_f),
        bg_color: (c["bg_color"] || "").to_s,
      }
    end

    {
      rows: rows,
      cols: cols,
      confidence_avg: (obj["confidence_avg"] || avg_conf(cells)),
      cells: cells,
    }
  end

  def avg_conf(cells)
    return 0.0 if cells.empty?
    cells.sum { |c| c[:confidence].to_f } / cells.size.to_f
  end

  def default_openai_client
    OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])
  end

  def default_logger
    defined?(Rails) ? Rails.logger : Logger.new($stdout)
  end
end
