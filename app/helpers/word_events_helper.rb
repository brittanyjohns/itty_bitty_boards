module WordEventsHelper
  def heat_map
    word_events.group_by_day(:timestamp).count.map do |date, count|
      { date: date.strftime("%Y-%m-%d"), count: count }
    end
  end

  def week_chart_data(start_date, end_date)
    word_events_to_use = word_events.where(timestamp: start_date..end_date)
    word_events_to_use.group_by_day(:timestamp, range: start_date..end_date).count.map do |date, count|
      { date: date.strftime("%m-%d"), count: count }
    end
  end

  def week_chart
    week_chart_data(7.days.ago, Time.current)
  end

  def two_day_chart
    word_events.group_by_day(:timestamp, range: 2.days.ago..Time.current).count.map do |date, count|
      { date: date.strftime("%m-%d"), count: count }
    end
  end

  def group_week_chart
    child_accounts.map { |child_account| { label: child_account.name, data: child_account.week_chart, bg_color: child_account.bg_color } }
  end

  def board_week_chart
    boards.map { |board| { label: board.name, data: board.week_chart, bg_color: board.chart_bg_color } }
  end

  def most_clicked_words(range = 7.days.ago..Time.current, limit = 20)
    word_events.group(:word).where(timestamp: range).count.sort_by { |_, v| -v }.first(limit).sort_by { |_, v| -v }.map do |word, count|
      { word: word, count: count }
    end
  end
end
