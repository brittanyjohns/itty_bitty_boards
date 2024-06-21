# == Schema Information
#
# Table name: messages
#
#  id         :bigint           not null, primary key
#  subject    :string
#  body       :text
#  user_id    :integer
#  user_email :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Message < ApplicationRecord

    def update_message_list
        puts "Updating message list"
        
    end
end
