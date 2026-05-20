module WordEventsHelper
  def heat_map(range = nil)
    grouped = if range
      word_events.group_by_day(:timestamp, range: range)
    else
      word_events.group_by_day(:timestamp)
    end
    grouped.count.map do |date, count|
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

  # Aggregate summary metrics for the word events that fall inside `range`.
  def word_events_summary(range)
    events = word_events.where(timestamp: range)
    total = events.count
    by_day = events.group_by_day(:timestamp).count
    active_days = by_day.size
    busiest = by_day.max_by { |_, count| count }
    top = events.where.not(word: nil).group(:word).count.max_by { |_, count| count }
    {
      total_events: total,
      unique_words: events.where.not(word: nil).distinct.count(:word),
      active_days: active_days,
      most_active_day: busiest && { date: busiest.first.strftime("%Y-%m-%d"), count: busiest.last },
      avg_per_active_day: active_days.zero? ? 0 : (total.to_f / active_days).round(1),
      top_word: top && { word: top.first, count: top.last },
    }
  end

  # Counts word events inside `range` grouped by the linked image's part of speech.
  def part_of_speech_breakdown(range)
    word_events.where(timestamp: range)
               .joins(:image)
               .group("images.part_of_speech")
               .count
               .map { |part_of_speech, count| { label: part_of_speech.presence || "unknown", count: count } }
               .sort_by { |entry| -entry[:count] }
  end
end
