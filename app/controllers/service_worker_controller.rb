class ServiceWorkerController < ApplicationController
  protect_from_forgery except: :service_worker
  # No `skip_before_action :authenticate_user!` here: no ancestor registers that
  # callback, so skipping it raises "callback has not been defined" under eager
  # loading. These actions are public either way.
  def service_worker
  end

  def manifest
  end
end
