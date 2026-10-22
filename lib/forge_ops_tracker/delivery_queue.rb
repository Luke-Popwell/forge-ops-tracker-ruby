require "thread"

module ForgeOpsTracker
  # A small in-process background thread + bounded queue, so delivery never
  # blocks the request that raised the error and never depends on the host
  # app having any particular job backend configured. The worker thread is
  # started lazily on first push (not at load time), so it's created fresh
  # in each forked Puma/Passenger worker process rather than being carried
  # across a fork, which would leave it dead in the child.
  class DeliveryQueue
    # The most a normal process exit waits for queued events to go out (see #drain): long enough for
    # one delivery at the default open_timeout + read_timeout, short enough that an unreachable
    # ForgeOps never holds up a deploy or a cron run for long.
    DRAIN_TIMEOUT = 5

    # deliver_with names the Client method each payload goes through: :deliver (error events) by
    # default, :deliver_change for ForgeOpsTracker.record_change's own queue.
    def initialize(configuration, client: Client.new(configuration), deliver_with: :deliver)
      @configuration = configuration
      @client = client
      @deliver_with = deliver_with
      @queue = SizedQueue.new(configuration.queue_size)
      @mutex = Mutex.new
      @thread = nil
      @in_flight = 0
      @drain_registered = false
    end

    # Sends whatever is still queued, and lets a delivery already under way finish, before the
    # process exits, within DRAIN_TIMEOUT. Without it a short-lived process (a rake task, a cron
    # script, `rails runner`) lost every error it reported in its last moments: the worker thread
    # dies with the process before it gets to them. Delivers here on the exiting thread rather than
    # waiting on the worker, which in a forked child is a parent's thread that no longer runs.
    def drain(timeout: DRAIN_TIMEOUT)
      deadline = monotonic_now + timeout
      while monotonic_now < deadline
        payload = begin
          @queue.pop(true)
        rescue ThreadError
          break
        end
        deliver(payload)
      end
      sleep 0.01 while @in_flight.positive? && monotonic_now < deadline
    rescue StandardError => e
      log { "drain failed: #{e.class}: #{e.message}" }
    end

    # Enqueues a payload, dropping it silently (never blocking the caller)
    # if the queue is already full; a burst of exceptions must never apply
    # backpressure to the host app.
    def push(payload)
      ensure_worker_started
      @queue.push(payload, true)
      true
    rescue ThreadError
      log { "delivery queue full, dropping event" }
      false
    end

    private
      attr_reader :configuration, :client

      def ensure_worker_started
        register_drain
        return if @thread&.alive?

        @mutex.synchronize do
          return if @thread&.alive?

          @thread = Thread.new { run }
          @thread.abort_on_exception = false
        end
      end

      def run
        loop do
          payload = @queue.pop
          @in_flight += 1
          begin
            deliver(payload)
          ensure
            @in_flight -= 1
          end
        rescue StandardError => e
          log { "delivery thread error: #{e.class}: #{e.message}" }
        end
      end

      # One attempt per payload, as it has always been: a queued event is never held back for a
      # retry, whatever the outcome, so all that is left to do with a refusal is to say so once.
      def deliver(payload)
        case DeliveryStatus.from(client.public_send(@deliver_with, payload))
        when DeliveryStatus::REJECTED
          log { "dropping event: the server rejected it and will not accept a retry" }
        when DeliveryStatus::FAILED
          log { "dropping event: delivery failed" }
        end
      end

      # Registered on the first push, not at load, so a process that never reports anything never
      # waits on exit at all.
      def register_drain
        return if @drain_registered

        @mutex.synchronize do
          return if @drain_registered

          @drain_registered = true
          at_exit { drain }
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def log
        configuration.logger&.debug { "[ForgeOpsTracker] #{yield}" }
      end
  end
end
