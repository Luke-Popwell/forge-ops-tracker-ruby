module ForgeOpsTracker
  # Buckets a single duration into one of a fixed set of latency-range labels, the building block
  # PerformanceFlusher uses to accumulate an approximate distribution (not just count/sum/max)
  # alongside every [transaction_name, kind] bucket it already tallies. The server merges these
  # counts across matching samples at read time and walks cumulative counts to approximate a
  # percentile, the same "accurate to the bucket width, not exact" trade-off Prometheus's own
  # histogram_quantile makes: this SDK does not store, or need, the raw duration list a true
  # percentile would require.
  #
  # BOUNDARIES_MS is duplicated (not shared via a gem dependency) on the server side, in
  # app/services/histogram_percentile.rb: the gem and the Rails app it reports to are separate
  # deployables, the same "duplicated, not imported, so this package's own dependency graph stays
  # independent" reasoning already applied elsewhere in this repo (e.g. the React Native SDK's own
  # copy of the TypeScript SDK's PII scrubber). Change one, change the other, or a released gem
  # version and the server version it talks to would silently disagree about what each bucket label
  # means.
  module HistogramBucketer
    BOUNDARIES_MS = [ 50, 100, 250, 500, 1000, 2500, 5000, 10_000 ].freeze

    # Returns the label (a String) of the smallest boundary duration_ms fits under, or "inf" for
    # anything larger than the largest boundary. String, not Integer/Float: this travels as a JSON
    # object key once flushed (see PerformanceFlusher#flush), and JSON object keys are always
    # strings regardless of what Ruby type builds the Hash locally, so returning a String here
    # keeps the in-process Hash's own keys identical to what actually goes over the wire, rather
    # than looking different locally and then silently getting stringified only at serialization
    # time.
    def self.bucket_for(duration_ms)
      boundary = BOUNDARIES_MS.find { |b| duration_ms <= b }
      boundary ? boundary.to_s : "inf"
    end
  end
end
