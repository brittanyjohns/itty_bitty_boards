class VisionParser
  def initialize(image_path) @image_path = image_path end

  def parse!
    # Uses OpenAI responses API (vision). Replace with your existing client if you have one.
    # Expected JSON shape:
    # { rows: Integer, cols: Integer, confidence_avg: Float,
    #   cells: [{row:, col:, label:, confidence:, bbox:[x,y,w,h]}] }

    prompt = <<~PROMPT
      Return ONLY strict JSON. Detect the AAC grid (rows, cols). For each visible button, return:
      - row (0-index), col (0-index)
      - label (plain text; empty if unreadable)
      - confidence (0..1)
      - bbox [x, y, w, h] in image pixels.
      Do not invent words. If unsure, label="" and confidence=0.2.
    PROMPT

    # Build multipart with the image
    require "json"
    require "net/http"
    uri = URI("https://api.openai.com/v1/responses")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req["Content-Type"] = "application/json"

    base64 = Base64.strict_encode64(File.binread(@image_path))
    req.body = {
      model: "gpt-4.1-mini",  # pick the image-capable model you’re using
      input: [
        { role: "system", content: "You convert AAC board screenshots into grid JSON." },
        {
          role: "user",
          content: [
            { type: "input_text", text: prompt },
            { type: "input_image", image_data: "data:image/jpeg;base64,#{base64}" }
          ]
        }
      ],
      # helpful for JSON-only
      text_format: { type: "json_object" }
    }.to_json

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "Vision API error: #{res.code} #{res.body}" unless res.code.to_i.between?(200,299)

    body = JSON.parse(res.body)
    raw = body.dig("output", "text") || body.dig("output", 0, "content", 0, "text")
    parsed = JSON.parse(raw) rescue fallback_best_effort(raw)

    normalize_response(parsed)
  end

  private

  def fallback_best_effort(raw)
    # Very defensive: try to extract JSON object if the model added stray chars
    first = raw.index("{"); last = raw.rindex("}")
    JSON.parse(raw[first..last])
  end

  def normalize_response(obj)
    rows = (obj["rows"] || 6).to_i
    cols = (obj["cols"] || 8).to_i
    cells = (obj["cells"] || []).map do |c|
      {
        row: c["row"].to_i,
        col: c["col"].to_i,
        label: (c["label"] || "").to_s,
        confidence: (c["confidence"] || 0.0).to_f,
        bbox: Array(c["bbox"] || [0,0,0,0]).map(&:to_f)
      }
    end
    {
      rows: rows,
      cols: cols,
      confidence_avg: (obj["confidence_avg"] || avg_conf(cells)),
      cells: cells
    }
  end

  def avg_conf(cells)
    return 0.0 if cells.empty?
    cells.sum { |c| c[:confidence].to_f } / cells.size.to_f
  end
end
