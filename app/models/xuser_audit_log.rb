# class UserAuditLog < AuditLog::Log
#   belongs_to :user, class_name: "User", foreign_key: "user_id"

#   scope :for_user, ->(user) { where(user_id: user.id) }
#   scope :for_action, ->(action) { where(action: action) }

#   def print
#     "#{user.email} - #{action} - #{payload}"
#   end

#   def audit!
#     user.user_audit_logs.create!(action: action, payload: payload, request: request, word: word, previous_word: previous_word)
#   end

#   def self.search_payload_for_word(word)
#     where(word: word)
#   end

#   def save
#     # custom pre-save logic
#     self.word = payload["word"]
#     self.previous_word = payload["previous_word"]
#     super
#     # custom post-save logic
#   end
# end
