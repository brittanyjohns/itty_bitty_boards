module WordEventsHelper
  def heat_map
    word_events.group_by_day(:timestamp).count.map do |date, count|
      { date: date.strftime("%Y-%m-%d"), count: count }
    end
  end
end
