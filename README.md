# ForgeOpsTracker

Exception reporting client for [ForgeOps](https://getforgeops.net), for Rails, plain Rack and
Sinatra apps, and scripts.

> For health or personal data, turn on [strict privacy](#strict-privacy): the SDK then sends only structured facts about each error (its type, stack trace, release and route), never the message, a raw path, breadcrumbs, or context you haven't allowed.

## Installation

```ruby
gem "forge_ops_tracker", path: "gems/forge_ops_tracker" # or git: "..." once split into its own repo
```

## Configuration

Set a DSN (from a project's settings page in ForgeOps) via an initializer or environment variable:

```ruby
# config/initializers/forge_ops_tracker.rb
ForgeOpsTracker.configure do |config|
  config.dsn = ENV["FORGE_OPS_DSN"] # "https://<api_key>@getforgeops.net/api/v1/events"
  config.release = ENV["HEROKU_SLUG_COMMIT"] || `git rev-parse HEAD`.strip
  config.enabled_environments = %w[production staging] # default; reporting is a no-op elsewhere

  # Trace propagation to the services you call (see "Tracing" below):
  config.propagate_traces = true           # default; false stops sending the traceparent header
  config.trace_propagation_targets = nil   # default: every host; or e.g. ["internal.example", /\.svc\z/]
end
```

The environment is `FORGE_OPS_ENVIRONMENT` when set, otherwise `Rails.env` under Rails, and
outside Rails `RAILS_ENV`, then `RACK_ENV`, then `production`. Only `production` and `staging`
send by default, so a Rails app in development or test doesn't report. When a DSN is set but the
environment isn't enabled, one warning is logged per process (at boot under Rails) saying so.

Delivery happens on a small background thread with a bounded queue and short HTTP timeouts. Every
failure mode (network errors, timeouts, a full queue, a malformed DSN) is caught and dropped
rather than raised, so a broken or unreachable tracker can never take down the host app.

## What gets reported automatically, and what doesn't

**Unhandled exceptions need no further wiring at all.** The gem's Railtie subscribes to
`Rails.error` automatically, and Rails itself reports anything that crashes a request or job
through that same channel: install the gem, set a DSN, and those show up in ForgeOps with zero
other code changes.

**Handled exceptions (code that catches its own error to keep running) are a different story.**
A plain `rescue` the gem never hears about, no matter what:

```ruby
begin
  charge_card(order)
rescue Stripe::CardError => e
  logger.warn("card declined: #{e.message}")
  # ForgeOps never sees this: nothing here goes through Rails.error at all.
end
```

To report it *and* keep swallowing it, swap the bare `rescue` for Rails' own built-in
`Rails.error.handle`: this isn't a ForgeOps-specific API, it's Rails' own error-reporting
convention (Rails 7+), which the gem just happens to already be subscribed to:

```ruby
Rails.error.handle(fallback: -> { nil }) do
  charge_card(order)
end
# Reported to every Rails.error subscriber, including this gem, then swallowed:
# execution continues past the block either way.
```

Or `Rails.error.record`, if you want it reported *and* still raised (e.g. so a background job's
own retry logic still sees the failure):

```ruby
Rails.error.record { charge_card(order) } # reports, then re-raises
```

Bottom line: if an exception would otherwise crash something, you're already covered. If your own
code already catches and handles it, route that specific `rescue` through `Rails.error.handle`/
`.record` instead of a bare one wherever you want ForgeOps to know about it.

### Outside Rails: Rack, Sinatra, and scripts

Without Rails there's no `Rails.error`, so add the Rack middleware, which reports any exception
escaping your app (and, in Sinatra, an error it turned into a 5xx response itself), then re-raises
it unchanged:

```ruby
# config.ru, or inside a Sinatra::Base subclass
require "forge_ops_tracker"

ForgeOpsTracker.configure do |config|
  config.dsn = ENV["FORGE_OPS_DSN"]
end

use ForgeOpsTracker::Middleware::RequestContext
```

Report an exception you rescued yourself, anywhere (Rails included), with
`ForgeOpsTracker.capture_exception`:

```ruby
begin
  charge_card(order)
rescue Stripe::CardError => e
  ForgeOpsTracker.capture_exception(e, context: { order_id: order.id })
end
```

### Sidekiq job failures and renamed job classes

A failing Sidekiq job is reported through `Rails.error` like any other error. Since 0.10.1 the issue
carries the real error, not Sidekiq's internal `Sidekiq::JobRetry::Handled` retry wrapper (which is
what every failing job used to arrive as, whatever went wrong inside it).

Renaming or removing a job class breaks every job still queued under the old name, since Sidekiq
stores the class name as a string, and no test can catch it because those jobs live in Redis. ForgeOps
recognizes that failure (an Active Job `UnknownJobClassError`, or a plain Sidekiq job's `NameError`
from constantizing the class), names the class that no longer exists, and shows how soon after which
release it first appeared. Keep the old name as an alias until the queue, retry set and scheduled set
have drained:

```ruby
# app/jobs/send_invoice_job.rb
# Kept only until jobs queued under the old name have drained, then delete this file.
SendInvoiceJob = DeliverInvoiceJob
```

## Identifying users

If you're using Devise, or any other Warden-based authentication, the currently signed-in user is
already associated with every error automatically, on by default, no setup needed:

```ruby
ForgeOpsTracker.configure do |config|
  config.track_current_user = false # opt out entirely
end
```

For a custom auth setup this can't detect, or to override its guess, call
`ForgeOpsTracker.set_user` yourself:

```ruby
before_action do
  ForgeOpsTracker.set_user(id: current_user&.id, email: current_user&.email)
end
```

Also usable outside a request entirely, a background job or a console session, for the rest of
whichever thread calls it. `id`/`email`/`username` are all independently optional; call it with
none of them (or with a signed-out `current_user`, as the `&.` above already handles) to clear
whatever was set. Shows up on an issue's own detail page, and as its own `affected_users_count`
alongside the regular event count.

## Where an error happened

An error reported during a request carries three extra fields, filled in as soon as the
controller starts handling the request (so an error reported from inside the action with
`Rails.error.handle`/`.record` has them too):

- `transaction_name`: the controller and action, `"CheckoutsController#create"`, the same name
  performance monitoring and traces use.
- `endpoint`: the HTTP method and the route as declared in your routes file, `"POST /checkout"` or
  `"GET /orders/:id"`. Never the literal path, so an id or a token in the URL never ends up here.
  Before Rails 7.1 (which added the route pattern to the request), this falls back to
  `"POST CheckoutsController#create"`.
- `trace_id`: the request's W3C trace id, which ForgeOps uses to link this error to errors that
  other services reported for the same trace (see "Tracing" below).

They're left out entirely outside a request (a background job, a console session), and they're
never PII-scrubbed, like `environment` and `release`: they're structured fields, not free text.

An unhandled exception keeps these, the affected user, and the breadcrumb trail, even though Rails
reports it after this gem's middleware has already finished with the request: the innermost
middleware, `ForgeOpsTracker::Middleware::RequestContext`, copies them onto the exception on its
way out and re-raises it unchanged.

## Breadcrumbs

A trail of what happened right before an error, on by default, no setup needed: every SQL query,
controller action, and outbound `Net::HTTP` call during a request is recorded automatically, and
shows up alongside the error on an issue's own detail page.

```ruby
ForgeOpsTracker.configure do |config|
  config.track_breadcrumbs = false # opt out of the automatic sources entirely
  config.max_breadcrumbs = 30 # oldest entry dropped once this many have accumulated in one request
end
```

Add your own by hand, regardless of whether the automatic sources are on:

```ruby
ForgeOpsTracker.add_breadcrumb("charged card", category: "billing", data: { order_id: order.id })
```

`category` defaults to `"custom"`, `level` to `"info"` (`"debug"`/`"info"`/`"warning"`/`"error"`
are the four levels the automatic sources themselves use too), and `data` to `{}`. Works outside a
request entirely too (a background job, a console session): the buffer it adds to is created
lazily on whatever thread calls it, the same "works standalone, no specific setup required" shape
`ForgeOpsTracker.set_user` already has, rather than silently doing nothing with no
`ForgeOpsTracker::Middleware::BreadcrumbContext` around it.

Each request gets its own fresh, bounded trail (a ring buffer capped at `max_breadcrumbs`, oldest
entry dropped once full): scoped to the current thread the same way `ForgeOpsTracker.set_user`'s
own thread-local is, so one request's trail never bleeds into another's on a reused Puma thread.
Unlike the affected user above, a breadcrumb's `message`/`data` **is** scrubbed for likely PII:
console-style/query/request trail entries are exactly the kind of free text (a bind parameter
showing up in a message, a URL with a token in it) the scrubber exists to catch, not a
deliberately-structured field the way `user` is.

## PII scrubbing

By default, the message, backtrace, and any context/tags you attach are scanned for likely
personal data: email addresses, formatted SSNs/credit cards, known API key/token formats, and
anything under a suspiciously-named key (`password`, `api_key`, `ssn`, and similar); redacted
before the payload ever leaves this process. ForgeOps itself scrubs again on arrival regardless, so
this is a second, earlier layer, not the only one. The user identified via automatic Warden
detection or `ForgeOpsTracker.set_user` above is a deliberate exception: it's never scrubbed,
since redacting it would defeat the whole point of identifying users in the first place.

To disable it (e.g. if your app already scrubs its own error context, or you have your own reasons
to want the raw payload):

```ruby
ForgeOpsTracker.configure do |config|
  config.scrub_pii = false
end
```

## Strict privacy

For apps that can't let personal or health data (PII, PHI) leave their own servers. With strict
privacy on, the gem sends only structured facts about an error (its class, its stack frames'
file, line and method, the release, environment, server, the request's `transaction_name` and
trace id, and the database tables or procedures involved), never free text that could hold a
name, an email or a diagnosis:

- No error message. A `message_fingerprint` is sent instead: a one-way hash of the message with
  its numbers, hex ids and UUIDs taken out, computed in your process, so errors still group
  without the message ever leaving it.
- No breadcrumbs (they aren't recorded at all), no `endpoint`, no SQL statement even with
  `capture_sql_statement` on, and no source context (the source file is never read).
- The user is sent by `id` only, never `email` or `username`.
- Context and tags only keep the top-level keys you list in `privacy_allowed_fields`, and only
  when the value is a string, number or boolean. Nothing else from them is sent.
- Failed jobs and outbound calls keep their error class, never their error message.
- A `transaction_name` that is a raw path rather than a route or `Controller#action` keeps only
  its first segment (`GET /patients/jane-doe/12` is sent as `GET /patients/:path`; a first
  segment with a digit becomes `:id`), in error events, performance samples, failure events and
  spans alike. A route template such as `/patients/:id/notes` is kept as it is.
- Outbound HTTP spans are named by method and host only (`GET api.example.com`), and span data
  keeps only the masked `db.statement` and `db.system`.

```ruby
ForgeOpsTracker.configure do |config|
  config.strict_privacy = true                           # default false
  config.privacy_allowed_fields = %w[error_code feature] # default []
end
```

Both can also come from the environment: `FORGE_OPS_STRICT_PRIVACY=true` and
`FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature` (comma separated). A value set in
`configure` wins over the environment.

ForgeOps applies the same rules again on arrival when the project's own Strict privacy setting is
on, so an app with an older gem, or one with this option off, still can't get that text stored.

## Source context

By default, each in-app backtrace frame (never a vendored gem) is captured along with the 5 lines
of source on either side of the culprit line, read straight off disk at raise-time, so an issue's
detail page can show the actual code that broke, not just a `file:line:method` reference. This
never applies to a frame outside `app_root`, and it fails silently (no context, not an error) for
any file that can't be read for whatever reason.

This is a real, deliberate exception to "off by default is safer": literal source code is being
transmitted, not just a reference to it, and the real protection here is not this flag. Every
project on ForgeOps has its own setting (on by default, off durably and immediately once an org
owner turns it off, regardless of what any individual app's own `config.capture_source_context` is
still set to) that governs whether the server will ever actually store what an SDK sends; see the
in-app help docs. Use this flag if you'd rather this gem never even attempt the disk read in the
first place:

```ruby
ForgeOpsTracker.configure do |config|
  config.capture_source_context = false
end
```

## Database errors

When an error comes from a database call (`ActiveRecord::StatementInvalid`, or your own exception
raised from one), the event carries the names of the stored procedure or function and the tables or
views its SQL touched, so the issue tells you where to start looking. This is on by default and
sends identifiers only, never values. A view and a table are written the same way in SQL, so both
show as tables/views; the database's own error message usually settles which it was.

To also send the SQL statement itself, opt in. Every string and number is replaced by `?` before it
leaves your process (`WHERE email = 'a@b.co' AND id = 42` is sent as `WHERE email = ? AND id = ?`),
and ForgeOps masks it again on arrival:

```ruby
ForgeOpsTracker.configure do |config|
  config.capture_sql_statement = true # default false
  config.capture_sql_objects = false  # default true; false stops even the names
end
```

Each ForgeOps project also has its own "Capture the SQL behind database errors" setting. Turn it off
there and the statement is never stored for that project, whatever this flag says; the names are
still kept.

## Session tracking (release health)

By default, every request is counted as a session: crash-free unless an unhandled exception
actually escapes it, giving ForgeOps a crash-free rate per release to show alongside the errors
themselves, not just the errors on their own. Counted in-process and flushed as a small periodic
aggregate on a background thread (never one network call per request), the same delivery
philosophy as everything else in this gem: a broken or unreachable tracker never affects the host
app either way.

```ruby
ForgeOpsTracker.configure do |config|
  config.track_sessions = false   # opt out entirely
  config.session_flush_interval = 30 # seconds; default 60
end
```

Requires a ForgeOps plan that includes release health; on a plan that doesn't, the periodic
flushes are accepted but not recorded, and the response says why.

## Performance monitoring

By default, every request's controller/action duration is timed (via Rails' own
`process_action.action_controller` instrumentation, no extra middleware needed) so a dashboard
widget on ForgeOps can show which parts of your app are actually slow, not just which ones raise.
Bucketed by transaction ("PostsController#show") and flushed as a small periodic aggregate per
transaction on a background thread, the same delivery philosophy as session tracking above: a
broken or unreachable tracker never affects the host app either way.

Each aggregate carries a small latency histogram alongside its count/sum/max, so ForgeOps can show
an approximate p50/p95/p99 per transaction, not just an average: accurate to the width of whichever
latency bucket a duration falls into (50/100/250/500/1000/2500/5000/10000ms), the standard
histogram-quantile trade-off (the same one Prometheus's own `histogram_quantile` makes) rather than
storing every individual request's own duration.

```ruby
ForgeOpsTracker.configure do |config|
  config.track_performance = false   # opt out entirely
  config.performance_flush_interval = 30 # seconds; default 60
end
```

Requires a ForgeOps plan that includes performance monitoring; on a plan that doesn't, the
periodic flushes are accepted but not recorded, and the response says why.

### Database queries, background jobs, and outbound HTTP calls

The same automatic instrumentation, on the same `track_performance` flag, also covers:

- **Database queries**, via `sql.active_record`: bucketed by Rails' own auto-generated query name
  ("User Load", "Order Create"), not the raw SQL text. Internal schema-introspection queries
  ("SCHEMA") and cached reads (never a real round trip to the database) are skipped.
- **Background jobs**, via `perform.active_job`: bucketed by job class. Covers any Active Job
  backend, Solid Queue included, with no backend-specific code needed. A second, independent
  sample, `kind: "job_latency"`, bucketed by queue name instead of job class, also records how long
  the job actually waited in its queue before this run started: `nil`, and skipped, for a job run
  via `perform_now`, which never goes through `enqueue` at all and so has no queue wait to report.
- **Raw Sidekiq workers** (a `Sidekiq::Worker`/`Sidekiq::Job` not dispatched through Active Job):
  a server middleware, registered automatically when Sidekiq is already loaded. A job dispatched
  through Active Job and run on Sidekiq is still only counted once, by the Active Job hook above,
  not twice.
- **Outbound `Net::HTTP` calls**, bucketed by `"<method> <host>"`, never the full URL (a path or
  query string could carry an id or a token). Most other Ruby HTTP client libraries (Faraday's own
  `net_http` adapter, HTTParty, RestClient) ultimately call through `Net::HTTP`, so this covers
  those too as a side effect.

Every one of these shows up as its own `kind` ("controller", "job", "job_latency", "query", "http")
on the same `performance` dashboard dataset, so "slowest jobs" and "slowest queries" are just a
filtered version of the same widget builder "slowest transactions" already uses.

### Sidekiq, Solid Queue, Puma, and ActiveRecord gauges

Also on by default whenever the corresponding library is already loaded: Sidekiq's own aggregate
stats (`Sidekiq::Stats`: processed/failed/scheduled/retry/dead counts, plus a queue-depth
reading per queue), Solid Queue's own state (active workers, active dispatchers, failed/scheduled/
blocked counts, a queue-depth reading per queue), Puma's own thread pool (backlog, running threads,
pool capacity), and this process's own ActiveRecord connection pool (size, busy count, waiting
count, and a derived utilization percent). Reported as ordinary infrastructure metrics
(`sidekiq.queue_depth.default`, `puma.backlog`, `active_record_pool.utilization_pct`, and so on) via
the same `capture_infrastructure_metric` call your own scripts use, on a periodic timer:

```ruby
ForgeOpsTracker.configure do |config|
  config.gauge_poll_interval = 30 # seconds; default 60
end
```

No separate opt-out: these are gated by the same `track_performance` flag as everything else in
this section, not a flag of their own.

## Failure tracking

On by default, from the same two instrumentation points performance monitoring already uses:

- **Background jobs**: a job whose `perform` raised, via the existing `perform.active_job`
  subscription. Not just an aggregate failure count; each occurrence carries the job class, the
  raised exception's class name, and its message.
- **Outbound `Net::HTTP` calls**: a request that raised, or came back with a 5xx status (a 4xx is
  a response the dependency actually gave, not a failure of the dependency itself).

```ruby
ForgeOpsTracker.configure do |config|
  config.track_failures = false        # opt out entirely
  config.failure_event_flush_interval = 30 # seconds; default 60
end
```

**Known, honest gap**: `Net::HTTP.get_response` and the `Net::HTTP.start { |http| ... }` block
form both open the TCP connection before the block (and so before `#request`, the only method
this gem wraps) ever runs, so a connection-refused or DNS-failure error raised during that setup
is invisible here, for the same reason it's already invisible to this gem's own outbound-HTTP
breadcrumbs and timing. `Net::HTTP.new(host, port).request(...)` (no explicit `#start`) is
unaffected: confirmed directly that Net::HTTP connects lazily, inside `#request` itself, the first
time it's called on a not-yet-started instance.

Requires a ForgeOps plan that includes performance monitoring, the same plan feature performance
monitoring itself already requires; on a plan that doesn't, the periodic flushes are accepted but not recorded, and the response says why.

## Tracing

On by default: every request records a nested tree of spans (the controller action, SQL queries,
outbound `Net::HTTP` calls, Redis calls, and anything you wrap in
`ForgeOpsTracker.span("PaymentService#charge") { ... }`), kept in memory until the request ends.
Only some requests' traces are actually sent:

- a request at least `trace_capture_threshold_ms` slow (default 1000), and
- **every request that errored, however fast**: an unhandled exception, or any error reported
  through `Rails.error` (`handle`/`record`/`report`) while the request was running. The spans
  leading up to an error are exactly what you want next to it.

A fast, successful request never sends anything.

```ruby
ForgeOpsTracker.configure do |config|
  config.track_tracing = false             # opt out of recording spans entirely
  config.trace_capture_threshold_ms = 500  # default 1000
end
```

### Following a request across services

Traces use the [W3C Trace Context](https://www.w3.org/TR/trace-context/) standard, so a request
can be followed from one service into the next, whichever language or tracing library the other
service uses:

- **Incoming**: a request that arrives with a valid `traceparent` header continues that trace
  (same trace id), and its root span records the caller's span as its parent. A missing or
  malformed header just starts a new trace.
- **Outgoing**: every outbound `Net::HTTP` call made during a request (Faraday's `net_http`
  adapter, HTTParty, and RestClient included) gets a `traceparent` header whose parent id is that
  call's own span, so the next service's spans nest under it. A `traceparent` you set yourself is
  never replaced.

A trace id exists for every request even with `track_tracing` off, and the header is still sent,
since the trace id is also what links an error here to an error in the service you called.
Narrow or turn off where the header goes, for example if a third-party API rejects unknown
headers:

```ruby
ForgeOpsTracker.configure do |config|
  config.propagate_traces = false # never send traceparent (default true)

  # Default nil: every host. A String matches that host and its subdomains ("internal.example"
  # matches "orders.internal.example", not "notinternal.example"); a Regexp is matched against
  # the host.
  config.trace_propagation_targets = [ "internal.example", /\A10\.0\./ ]
end
```

Requires a ForgeOps plan that includes distributed tracing; on a plan that doesn't, traces are
accepted but not recorded, and the response says why. The `trace_id`
on error events is sent either way.

### The SQL behind each database span

Every Active Record query span carries the query's SQL and the database it ran on, so a slow trace
shows exactly which query was slow. The SQL is masked before it leaves your process: every string
and number is replaced by `?`, so `WHERE email = 'a@b.co' AND id = 42` is sent as
`WHERE email = ? AND id = ?`, and bind values are never sent at all. That includes escaped and
prefixed strings (`E'o\'brien'`, `X'DEADBEEF'`), hex, binary and exponent numbers (`0x1F`,
`0b101`, `1.5E-3`), and, on MySQL and MariaDB (where `"double quotes"` hold a string, not a name),
double-quoted strings. ForgeOps masks it again on arrival. The database comes from the
connection's adapter (`postgresql`, `mysql`, `sqlite`, `mssql`, `oracle`, or the adapter's own
name otherwise).

Spans you create yourself can carry SQL too. Pass `statement:` (and optionally `db_system:`) on a
`kind: "database"` span; it's masked the same way:

```ruby
sql = ActiveRecord::Base.sanitize_sql_array(
  [ "SELECT * FROM orders WHERE customer_id = ? AND status = ?", customer.id, "open" ]
)

ForgeOpsTracker.span("Load open orders", kind: "database", statement: sql, db_system: "postgresql") do
  ReportingDatabase.connection.select_all(sql)
end
# Sent as "SELECT * FROM orders WHERE customer_id = ? AND status = ?"
```

### Query plans for slow queries (PostgreSQL)

Opt in, and a slow `SELECT` also sends Postgres's plan for it, so ForgeOps can show why it was
slow (a sequential scan over a big table, a missing index, a bad join order):

```ruby
ForgeOpsTracker.configure do |config|
  config.explain_slow_queries = true # default false
  config.explain_threshold_ms = 500  # default 500; only queries at least this slow
end
```

What it does:

- For a query that took at least `explain_threshold_ms`, runs `EXPLAIN (FORMAT JSON)` with the
  same SQL and bind values, and sends the plan with the query's masked SQL. Every string inside the
  plan (a filter like `(email = 'a@b.co'::text)`) is masked the same way before it's sent. A plan
  over 64 KB is dropped rather than sent.
- Runs on the gem's own background thread, on a connection it checks out of your app's pool itself,
  inside its own `READ ONLY` transaction with a 2 second `statement_timeout`, always rolled back.
  Never on the connection your request is using, and never inside your request's transaction.
- At most once per 10 minutes for each distinct (masked) query, and at most 10 per minute per
  process overall.

What it doesn't do:

- It never runs `EXPLAIN ANALYZE`, so your query is planned again but never executed again.
- It only explains a single plain `SELECT`: nothing that starts with anything else (including
  `WITH`), nothing with a second statement, no `FOR UPDATE`/`FOR SHARE` (or `FOR NO KEY UPDATE`/
  `FOR KEY SHARE`), and nothing with `INSERT`, `UPDATE`, `DELETE` or `MERGE` anywhere in it.
- It only runs on PostgreSQL. Other databases are left alone.
- It never raises into your app. A timeout, a permission error, an exhausted connection pool or
  anything else is logged at debug level and skipped.
- The original SQL and its bind values are only held in memory until the `EXPLAIN` runs. Only the
  masked SQL and the masked plan are sent.

It does use one pooled connection, briefly, for each plan. With the limits above that's at most 10
short checkouts a minute, but on a pool that's already at capacity, leave it off or raise
`explain_threshold_ms`. Plans are part of performance monitoring; on a plan without it, they're
accepted but not recorded, and the response says why.

## What changed

ForgeOps can show what changed in your system next to the errors and slowdowns that followed it.
Two ways in:

**Record a change yourself** when something changes that no deploy captures, like a feature flag
flipped, a config value edited, or a migration run by hand:

```ruby
ForgeOpsTracker.record_change(
  kind: "feature_flag", # feature_flag, config, migration, dependency, infrastructure, or other
  title: "Enabled new_checkout for 10% of users",
  details: { flag: "new_checkout", rollout_percent: 10 },
  actor: current_user.email,
  url: "https://flags.example.com/new_checkout"
)
```

`kind` and `title` are required; `details`, `environment` (defaults to `config.environment`),
`service`, `actor`, `url`, `id` (an idempotency key, so sending the same change twice records it
once), and `occurred_at` (defaults to now) are optional. An unknown `kind` is sent as `other`. It's
queued and sent from a background thread, so it never slows down the caller, never raises, and is
a no-op wherever reporting is off.

**Changes between deploys are detected for you.** Once per process, right after Rails finishes
booting, a background thread sends ForgeOps a snapshot of what the app is running: the Ruby
version, every gem version in your `Gemfile.lock`, and the current Active Record migration version
(left out if the database can't be reached). ForgeOps compares it with the previous boot's and
records whatever changed, such as a gem upgrade or a new migration. Outside Rails the snapshot goes
out when you call `ForgeOpsTracker.configure`, without the migration version.

```ruby
ForgeOpsTracker.configure do |config|
  config.detect_changes = true       # default; false sends no startup snapshot
  config.track_env_var_names = false # default; true also sends environment variable names
end
```

With `track_env_var_names` on, the snapshot lists the names of your environment variables (never
their values), so an added or removed variable shows up as a change. Names that differ from host to
host, like `HOSTNAME`, `PATH`, `PORT`, `LC_*`, and Kubernetes service variables, are left out, as
are the gem's own `FORGE_OPS_*` settings.

Requires a ForgeOps plan that includes change tracking; on a plan that doesn't, both are accepted but not recorded,
and the response says why.

## Custom metrics

Unlike session/performance tracking above, there's no automatic instrumentation here at all: a
signup or a payment isn't something this gem could ever detect on its own, so this is an explicit
call your own code makes. `value` defaults to `1.0` so a bare counter-style call needs no
argument; pass one for a metric with a real amount. Buffered and flushed as a batch on a
background thread, same delivery philosophy as everything else here, so this is safe to call from
inside a request (right after a signup completes, say) without adding network latency there.

```ruby
ForgeOpsTracker.capture_metric("signups")
ForgeOpsTracker.capture_metric("revenue", value: 49.00)

ForgeOpsTracker.configure do |config|
  config.metric_flush_interval = 30 # seconds; default 60
end
```

Requires a ForgeOps plan that includes custom metrics; on a plan that doesn't, the periodic
flushes are accepted but not recorded, and the response says why.

## Infrastructure monitoring

A deliberately different shape from everything above: there's no automatic instrumentation and no
ForgeOps-built agent. Run your own short-lived script on a cron entry or a systemd timer, reading
your own host's own stats; `hostname` defaults to the box the script is actually running on.
Buffered and flushed on exit, so a handful of capture calls in one short-lived process still cost
one network request, not several.

```ruby
# A cron entry or systemd timer runs this periodically, not your web app itself.
require "forge_ops_tracker"
ForgeOpsTracker.configure { |config| config.dsn = ENV["FORGE_OPS_DSN"] }

load_average = File.read("/proc/loadavg").split.first.to_f
ForgeOpsTracker.capture_infrastructure_metric("load_average", value: load_average)

meminfo = File.read("/proc/meminfo").lines.to_h { |line| line.split(":").map(&:strip) }
total_kb, available_kb = meminfo["MemTotal"].to_i, meminfo["MemAvailable"].to_i
ForgeOpsTracker.capture_infrastructure_metric("memory_used_percent",
  value: 100.0 * (total_kb - available_kb) / total_kb)

disk_used_percent = `df --output=pcent / | tail -1`.strip.delete("%").to_f
ForgeOpsTracker.capture_infrastructure_metric("disk_used_percent", value: disk_used_percent)
```

The example above is Linux-specific (`/proc/loadavg`, `/proc/meminfo`); on another OS, read that
platform's own equivalents instead. Requires a ForgeOps plan that includes infrastructure
monitoring; on a plan that doesn't, the periodic flushes are accepted but not recorded, and the response says why.
