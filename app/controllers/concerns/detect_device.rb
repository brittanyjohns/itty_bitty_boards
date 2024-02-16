module DetectDevice
    extend ActiveSupport::Concern
  
    included do
      before_action :set_variant
    end
  
    def set_variant
      #case request.user_agent
      #when /iPhone/
      #  request.variant = :phone
      #when /iPad/
      #  request.variant = :tablet
      #end
  
      browser = Browser.new(request.user_agent)
      if browser.mobile?
        request.variant = :phone
      elsif browser.tablet?
        request.variant = :tablet
      end
    end
end