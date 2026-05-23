require "faraday"

module Github
  class WorkflowDispatcher
    REPO = "brittanyjohns/speakanyway-printables".freeze
    DEFAULT_REF = "main".freeze
    API_HOST = "https://api.github.com".freeze

    WORKFLOWS = {
      "generate" => { file: "generate-printable.yml", label: "Generate printable" },
      "publish"  => { file: "publish.yml",            label: "Publish to Gumroad" },
      "seed"     => { file: "seed-idea.yml",          label: "Seed idea" },
    }.freeze

    Result = Struct.new(:ok?, :message, :actions_url, keyword_init: true)

    def self.workflow_label(key)
      WORKFLOWS.dig(key, :label) || key
    end

    def self.actions_url
      "https://github.com/#{REPO}/actions"
    end

    def self.dispatch(workflow:, inputs: {}, ref: DEFAULT_REF)
      meta = WORKFLOWS[workflow]
      return Result.new(ok?: false, message: "Unknown workflow: #{workflow}") if meta.nil?
      return Result.new(ok?: false, message: "GitHub PAT not configured") if token.blank?

      response = connection.post("/repos/#{REPO}/actions/workflows/#{meta[:file]}/dispatches") do |req|
        req.headers["Accept"] = "application/vnd.github+json"
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["X-GitHub-Api-Version"] = "2022-11-28"
        req.headers["Content-Type"] = "application/json"
        req.body = { ref: ref, inputs: inputs.compact_blank.transform_values(&:to_s) }.to_json
      end

      if response.status == 204
        Result.new(ok?: true, message: "Triggered #{meta[:label]}", actions_url: actions_url)
      else
        Result.new(ok?: false, message: github_error_message(response), actions_url: actions_url)
      end
    end

    def self.recent_runs(limit: 5)
      return [] if token.blank?

      response = connection.get("/repos/#{REPO}/actions/runs") do |req|
        req.headers["Accept"] = "application/vnd.github+json"
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["X-GitHub-Api-Version"] = "2022-11-28"
        req.params["per_page"] = limit
      end

      return [] unless response.success?

      JSON.parse(response.body).fetch("workflow_runs", []).map do |r|
        {
          name: r["name"],
          status: r["status"],
          conclusion: r["conclusion"],
          created_at: r["created_at"],
          html_url: r["html_url"],
          event: r["event"],
        }
      end
    rescue JSON::ParserError
      []
    end

    def self.token
      ENV["GITHUB_PRINTABLES_TOKEN"].presence ||
        Rails.application.credentials.dig(:github_printables_token).presence
    end

    def self.connection
      Faraday.new(url: API_HOST) do |f|
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
    end

    def self.github_error_message(response)
      body = JSON.parse(response.body) rescue {}
      msg = body["message"] || "GitHub API #{response.status}"
      msg.length > 200 ? "#{msg[0, 200]}…" : msg
    end

    private_class_method :token, :connection, :github_error_message
  end
end
