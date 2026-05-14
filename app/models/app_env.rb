module AppEnv
  def self.staging?
    ENV["STAGING"] == "true"
  end
end
