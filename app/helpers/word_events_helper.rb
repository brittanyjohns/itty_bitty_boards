module WordEventsHelper
  def heat_map
    word_events.group_by_day(:timestamp).count.map do |date, count|
      { date: date.strftime("%Y-%m-%d"), count: count }
    end
  end

  def week_chart_data(start_date, end_date)
    word_events.group_by_day(:timestamp, range: start_date..end_date).count.map do |date, count|
      { date: date.strftime("%m-%d"), count: count }
    end
  end

  def week_chart
    week_chart_data(7.days.ago, Time.current)
  end

  def group_week_chart
    charts = child_accounts.map { |child_account| { label: child_account.name, data: child_account.week_chart, bg_color: child_account.bg_color } }
    puts "CHARTS: #{charts.inspect}"
    charts
  end

  def most_clicked_words(range = 7.days.ago..Time.current, limit = 20)
    word_events.group(:word).where(timestamp: range).count.sort_by { |_, v| -v }.first(limit).sort_by { |_, v| -v }.map do |word, count|
      { word: word, count: count }
    end
  end
end
