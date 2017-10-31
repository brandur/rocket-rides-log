require "json"
require_relative "./api"

class Streamer
  def run
    loop do
      num_enqueued = run_once

      # Sleep for a while if we didn't find anything to enqueue on the last
      # run.
      if num_enqueued == 0
        $stdout.puts "Sleeping for #{SLEEP_DURATION}"
        sleep(SLEEP_DURATION)
      end
    end
  end

  def run_once
    num_enqueued = 0

    # Need at least repeatable read isolation level so that our DELETE after
    # enqueueing will see the same records as the original SELECT.
    DB.transaction(isolation_level: :repeatable_read) do
      records = StagedLogRecord.order(:id).limit(BATCH_SIZE)

      unless records.empty?
        RDB.multi do
          records.each do |record|
            # XADD mystream * data <JSON-encoded blob>
            RDB.xadd(STREAM_NAME, "*", "data", JSON.generate(record.data))

            $stdout.puts "Enqueued record: #{record.action} #{record.object}"
            num_enqueued += 1
          end
        end

        StagedLogRecord.where(Sequel.lit("id <= ?", records.last.id)).delete
      end
    end

    num_enqueued
  end

  # Number of records to try to stream on each batch.
  BATCH_SIZE = 1000
  private_constant :BATCH_SIZE

  # Sleep duration in seconds to sleep in case we ran but didn't find anything
  # to stream.
  SLEEP_DURATION = 5
  private_constant :SLEEP_DURATION
end

#
# run
#

if __FILE__ == $0
  # so output appears in Forego
  $stderr.sync = true
  $stdout.sync = true

  Streamer.new.run
end
