module ForgeOpsTracker
  # What became of one delivery attempt, as every Client#deliver_* method reports it. A bare
  # true/false could not tell "the server will never take this payload" apart from "try again
  # later", so a batch a plan or a validation rule refused was re-sent at every flush for as long
  # as the process lived.
  module DeliveryStatus
    # Any 2xx.
    DELIVERED = :delivered
    # A 4xx other than 408 and 429: sending the same payload again can only fail the same way.
    REJECTED = :rejected
    # A network error, a timeout, a 5xx, a 408 or a 429: worth another attempt later.
    FAILED = :failed

    RETRYABLE_CLIENT_ERRORS = [ 408, 429 ].freeze

    def self.for_code(code)
      code = code.to_i
      return DELIVERED if code.between?(200, 299)
      return REJECTED if code.between?(400, 499) && !RETRYABLE_CLIENT_ERRORS.include?(code)

      FAILED
    end

    # Reads whatever a client handed back. A status passes through; anything else is read the way
    # the old boolean contract was (truthy delivered, falsy failed for now), so a client injected
    # through a `client:` keyword that still answers true/false keeps working.
    def self.from(result)
      return result if [ DELIVERED, REJECTED, FAILED ].include?(result)

      result ? DELIVERED : FAILED
    end
  end

  # Decides, after each flush of one buffer/flusher, whether the batch it just sent is done with.
  # Delivered and rejected batches are let go of at once; one that failed for now is kept, but only
  # for MAX_FAILED_FLUSHES flushes in a row, so an outage (or a server answering 500 to one
  # particular batch) can never pin the same data in memory for the life of the process.
  class FlushOutcome
    MAX_FAILED_FLUSHES = 5

    # what names the batch in the debug log ("metrics", "performance samples").
    def initialize(configuration, what)
      @configuration = configuration
      @what = what
      @failed_flushes = 0
    end

    # True when the caller should remove what it just sent (delivered, or dropped), false when it
    # should keep it for the next flush.
    def release?(result)
      case DeliveryStatus.from(result)
      when DeliveryStatus::DELIVERED
        @failed_flushes = 0
        true
      when DeliveryStatus::REJECTED
        @failed_flushes = 0
        log { "dropping buffered #{@what}: the server rejected them and will not accept a retry" }
        true
      else
        @failed_flushes += 1
        return false if @failed_flushes < MAX_FAILED_FLUSHES

        @failed_flushes = 0
        log { "dropping buffered #{@what}: #{MAX_FAILED_FLUSHES} flushes in a row failed" }
        true
      end
    end

    private
      def log
        @configuration.logger&.debug { "[ForgeOpsTracker] #{yield}" }
      end
  end
end
