class TurboFailureApp < Devise::FailureApp
    # Compatibility for Turbo::Native::Navigation
    class << self
        def helper_method(name)
        end
    end

    include Turbo::Native::Navigation

    # Turbo Native requests that require authentication should return 401s to trigger the login modal
    def http_auth?
        turbo_native_app? || super
    end
end