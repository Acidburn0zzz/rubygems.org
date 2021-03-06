require 'zlib'

class FastlyLogProcessor
  class LogFileNotFoundError < ::StandardError; end

  extend StatsD::Instrument

  attr_accessor :bucket, :key

  def initialize(bucket, key)
    @bucket = bucket
    @key = key
  end

  def perform
    StatsD.increment('fastly_log_processor.processed')

    log_ticket = LogTicket.pop(key: key, directory: bucket)
    if log_ticket.nil?
      StatsD.increment('fastly_log_processor.extra')
      return
    end

    counts = download_counts(log_ticket)

    # TODO: wrap this in a transation when download update is in the DB

    Delayed::Worker.logger.info "Processed Fastly log counts: #{counts.inspect}"
    updates = munge_for_bulk_update(counts)
    # Temporary feature flag while we roll out fastly log processing
    if ENV['FASTLY_LOG_PROCESSOR_ENABLED'] == 'true'
      Download.bulk_update(updates)
    else
      # Just log & exit w/out updating stats
      StatsD.increment('fastly_log_processor.disabled')
    end
    processed_count = updates.sum { |_, _, v| v }
    log_ticket.update(status: "processed", processed_count: processed_count)
  end
  statsd_count_success :perform, 'fastly_log_processor.perform'

  # Takes an enumerator of log lines and returns a hash of download counts
  # E.g.
  #   {
  #     'rails-4.0.0' => 25,
  #     'rails-4.2.0' => 50
  #   }
  def download_counts(log_ticket)
    file = log_ticket.body
    raise LogFileNotFoundError if file.nil?
    enumerator = file.each_line

    enumerator.each_with_object(Hash.new(0)) do |log_line, accum|
      path, response_code = log_line.split[10, 2]
      # Only count successful downloads
      # NB: we consider a 304 response a download attempt
      if [200, 304].include?(response_code.to_i) && (match = path.match %r{/gems/(?<path>.+)\.gem})
        accum[match[:path]] += 1
      end

      accum
    end
  end
  statsd_count :download_counts, 'fastly_log_processor.download_counts'

  # Takes a hash of download counts and turns it into an array of arrays for
  # Download.bulk_update. E.g.:
  #   [
  #     ['rails', 'rails-4.0.0', 25 ],
  #     ['rails', 'rails-4.2.0', 50 ]
  #   ]
  def munge_for_bulk_update(download_counts)
    download_counts.map do |path, count|
      name = Version.rubygem_name_for(path)
      # Skip downloads that don't have a version in redis
      name ? [name, path, count] : nil
    end.compact
  end
end
