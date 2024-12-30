# module Turbo
#     class DeviseFailureApp < Devise::FailureApp
#       class << self
#           def helper_method(name)
#           end
#       end
#       include Turbo::Native::Navigation

#       def respond
#         if request_format == :turbo_stream
#           redirect
#         elsif turbo_native_app?
#           http_auth
#         else
#           super
#         end
#       end

#       def skip_format?
#         %w[html turbo_stream */*].include? request_format.to_s
#       end

#       # Turbo Native requests that require authentication should return 401s to trigger the login modal
#       def http_auth?
#           turbo_native_app? || super
#       end
#     end
# end
