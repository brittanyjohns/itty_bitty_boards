class BuildAdminBoardJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(admin_board_build_id)
    build = AdminBoardBuild.find_by(id: admin_board_build_id)
    return unless build

    Boards::AdminBuilder::Build.new(admin_board_build: build).call
  end
end
