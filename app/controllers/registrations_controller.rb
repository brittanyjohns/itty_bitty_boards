class RegistrationsController < Devise::RegistrationsController  
	def create    
		super  
	end  
  
	protected  

    def after_sign_up_path_for(resource)
        puts "\n\n**** Resource: #{resource.inspect}\n\n"
        if resource.is_a?(User)
          welcome_path
        else
          super
        end
    end  
end  