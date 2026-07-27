# Rejects throwaway addresses at signup. See config/disposable_email_domains.txt
# for why the list is static rather than API-backed.
class DisposableEmailDomains
  LIST_PATH = Rails.root.join("config", "disposable_email_domains.txt")

  # Loaded once per process. The list only changes on deploy.
  def self.domains
    @domains ||= begin
      LIST_PATH.readlines(chomp: true)
               .map { |line| line.strip.downcase }
               .reject { |line| line.empty? || line.start_with?("#") }
               .to_set
    rescue Errno::ENOENT
      Rails.logger.error "DisposableEmailDomains: #{LIST_PATH} missing — allowing all domains"
      Set.new
    end
  end

  def self.disposable?(email)
    domain = email.to_s.strip.downcase.split("@").last
    return false if domain.blank? || !email.to_s.include?("@")

    domains.include?(domain)
  end
end
