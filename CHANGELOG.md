# Changelog

## 0.19.0 (2026-10-20)

- Strict privacy: a raw request path now keeps only its first segment, and the rest is sent as
  `:path` (`/patients/jane-doe/12` becomes `/patients/:path`; a first segment with a digit or over
  40 characters becomes `:id`). Before, only segments holding a digit were replaced, so a path like
  `/patients/janedoe` went out whole. A route template (`/patients/:id/notes`, `{id}`, `<int:id>`,
  `[slug]`, `*path`) is kept as it is. This applies everywhere strict privacy names a request or a
  call by its path: span names and transaction names.

## 0.18.0 (2026-10-20)

- New `config.strict_privacy` (off by default, or `FORGE_OPS_STRICT_PRIVACY=true`) for apps that
  can't let personal or health data leave their servers. With it on, an error event carries no
  message (a `message_fingerprint` computed in your process is sent instead, so errors still
  group), no breadcrumbs, no `endpoint`, no SQL statement and no source context, and the user only
  by `id`. Failed jobs and outbound calls keep their error class but not their message, and
  outbound HTTP spans are named by method and host only, with no span data but `db.statement` and
  `db.system`. A `transaction_name` that is a raw path, not a route or `Controller#action`, has its
  ids taken out in error events, performance samples and failure events.
- New `config.privacy_allowed_fields` (or `FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature`):
  the context and tag keys strict privacy still sends, when their value is a string, number or
  boolean. Empty by default.

## 0.17.0 (2026-10-13)

- Fixed: a batch the server refused was re-sent at every flush for as long as the process lived,
  with everything recorded since added to it. Performance samples, custom and infrastructure
  metrics, session counts and failure events are now dropped when the server answers with a 4xx
  other than 408 or 429 (a 400, 401, 403, 413 or 422, for example), since sending the same batch
  again can only fail the same way. Once a metric buffer had filled up behind such a batch, every
  new metric was dropped too; that no longer happens.
- A batch that could not be delivered for now (a network error, a timeout, a 5xx, a 408 or a 429)
  is still kept for the next flush, but only for 5 flushes in a row. After the fifth it is dropped
  and the buffer starts clean, so a long outage no longer holds the same data in memory forever.
- The failure event buffer now holds at most 1000 entries; further ones are dropped until a flush
  lets go of them, the same way the metric buffers already behave.
- With a `config.logger`, each drop is logged once at debug with what was dropped and why, and a
  non-2xx answer is logged with its status code.
- Internal: `ForgeOpsTracker::Client#deliver` and its sibling `deliver_*` methods now return
  `:delivered`, `:rejected` or `:failed` instead of `true`/`false`. All three are truthy, so code
  calling `Client` directly should compare against `:delivered`. Nothing in the documented API
  changed.

## 0.16.0 (2026-10-02)

- Changed: outside Rails, the environment now defaults to `production` when nothing sets it (it
  was `development`). It comes from `FORGE_OPS_ENVIRONMENT`, then `RAILS_ENV`, then `RACK_ENV`,
  then `production`. Only `production` and `staging` send by default, so before this a plain Ruby
  or Rack process that set just a DSN sent nothing at all. To keep the old behavior there, set
  `FORGE_OPS_ENVIRONMENT=development` (or `RACK_ENV=development`, or `config.environment`).
- Changed: under Rails, `FORGE_OPS_ENVIRONMENT` now takes precedence over `Rails.env` when it's
  set. Without it nothing changes: development and test still don't send.
- When a DSN is set but the environment isn't in `enabled_environments`, one warning is now logged
  per process, naming the environment and how to send from it: at boot under Rails (to
  `Rails.logger`), otherwise from `configure`, the Rack middleware, or `capture_exception` (to
  `config.logger`, or stderr when there isn't one). Nothing is logged when no DSN is set.
- New `ForgeOpsTracker.capture_exception(error, context: {})` reports an exception you've rescued,
  through the same path `Rails.error` reports into, so it works without Rails too.
- Plain Rack and Sinatra apps are now covered: `use ForgeOpsTracker::Middleware::RequestContext`
  reports an exception escaping the app, and an error Sinatra itself turned into a 5xx response.
  Under Rails it still only adds request context, since `Rails.error` already reports those.

## 0.15.1 (2026-10-01)

- Errors reported just before a process exits are now sent before it ends. Delivery runs on a
  background thread, and a short-lived process (a rake task, a cron script, `rails runner`,
  including the test command on a project's setup page) could exit before that thread sent them,
  so they never arrived. On a normal exit the queue now sends what's left, waiting at most 5
  seconds, and only in a process that reported something.

## 0.15.0 (2026-09-29)

- SQL masking now also catches strings with a backslash-escaped quote (`'o\'brien'`,
  `E'o\'brien'`), prefixed strings (`E''`, `X''`, `N''`, `B''`, `U&''`, prefix included), hex,
  binary and exponent numbers (`0x1F`, `0b101`, `3e10`, `1.5E-3`, `.5`), and, on MySQL and
  MariaDB, `"double-quoted"` strings. `SqlStatement.mask` takes an optional `system:`, and
  database spans (including `ForgeOpsTracker.span`'s `db_system:`) pass their `db.system` to it.

## 0.14.0 (2026-09-25)

- Every Active Record database span now carries the query's SQL (`db.statement`), masked so every
  string and number is `?` and bind values are never sent, and the database it ran on
  (`db.system`: `postgresql`, `mysql`, `sqlite`, `mssql`, `oracle`, or the adapter's own name).
- `ForgeOpsTracker.span` takes optional `statement:` and `db_system:` on a `kind: "database"`
  span, masked the same way.
- New opt-in `config.explain_slow_queries` (default false) and `config.explain_threshold_ms`
  (default 500). On PostgreSQL, a single plain `SELECT` at least that slow gets a plain
  `EXPLAIN (FORMAT JSON)` (never `EXPLAIN ANALYZE`), run on a background thread with its own
  pooled connection, in a read-only transaction with a 2 second statement timeout that is always
  rolled back. The plan is sent with every string in it masked. Limited to once per 10 minutes per
  distinct query and 10 per minute per process; plans over 64 KB are dropped; any failure is
  logged at debug and never raised.

## 0.13.0 (2026-09-25)

- New `ForgeOpsTracker.record_change(kind:, title:, details: {}, environment: nil, service: nil,
  actor: nil, url: nil, id: nil, occurred_at: nil)` records something that changed in your system
  (a feature flag, a config value, a hand-run migration) so ForgeOps can show it next to the errors
  that followed. `kind` is one of `feature_flag`, `config`, `migration`, `dependency`,
  `infrastructure`, or `other`; anything else is sent as `other`. Sent from a background thread,
  never raises, and a no-op wherever reporting is off.
- Changes between deploys are now detected automatically. Once per process, after Rails finishes
  booting (or on `ForgeOpsTracker.configure` outside Rails), a background thread sends a snapshot of
  the Ruby version, the gem versions in `Gemfile.lock`, and the current Active Record migration
  version, and ForgeOps records whatever changed since the previous boot. New
  `config.detect_changes` (default true) turns this off.
- New `config.track_env_var_names` (default false) adds environment variable names, never values,
  to that snapshot. Host-specific names (`HOSTNAME`, `PATH`, `PORT`, `LC_*`, Kubernetes service
  variables, and others) and the gem's own `FORGE_OPS_*` settings are always left out.

## 0.12.0

- Every error event reported during a request now says where it happened: `transaction_name` (the
  same `CheckoutsController#create` name performance samples and traces already use), `endpoint`
  (the HTTP method plus the route as declared in your routes file, e.g. `POST /checkout` or
  `GET /orders/:id`, never the literal path, so no ids or tokens; falls back to
  `POST CheckoutsController#create` before Rails 7.1), and `trace_id` (the request's W3C trace id).
  All three are set as soon as the controller starts handling the request, so an error reported
  from inside the action with `Rails.error.handle`/`record` already has them. Left out entirely
  outside a request (a background job, a console session). Structured fields, so they're never
  PII-scrubbed.
- Unhandled request errors keep their context. Rails 8.1 reports an unhandled request exception
  from its executor, outside this gem's middleware, after the gem had already cleared its
  per-request state, so the affected user and the breadcrumb trail were missing on exactly those
  errors. A new innermost middleware, `ForgeOpsTracker::Middleware::RequestContext`, now copies the
  user, breadcrumbs, transaction name, endpoint, and trace id onto the exception on its way out
  (re-raising it unchanged), and the error subscriber falls back to that copy.
- Distributed tracing across services, using the W3C Trace Context standard. A request that
  arrives with a valid `traceparent` header continues that trace instead of starting its own, and
  its root span points at the caller's span. Every outbound `Net::HTTP` call made during a request
  now sends a `traceparent` header whose parent id is that call's own span, so the next service
  (any service that understands the standard, not only ones running this gem) can continue the
  trace. A `traceparent` you set yourself is never overwritten. New `config.propagate_traces`
  (default true) and `config.trace_propagation_targets` (default nil, meaning every host; or an
  array of host Strings, each matching that host and its subdomains, and/or Regexps) control where
  the header goes. A trace id is created for every request even with `track_tracing` off, since it
  is also what links an error to errors in other services.
- An errored request's trace is always sent, however fast it was: an unhandled exception, or any
  error reported through `Rails.error` while the request was running. Previously only requests
  slower than `trace_capture_threshold_ms` were sent. Fast, successful requests are unchanged.

## 0.11.0

- Database errors now say where to look. When an error comes from a database call
  (`ActiveRecord::StatementInvalid`, or an exception of yours raised from one), the event carries the
  names of the stored procedure or function and the tables or views its SQL touched, so ForgeOps can
  show them on the issue. On by default (`config.capture_sql_objects`); names are identifiers, never
  values. New opt-in `config.capture_sql_statement` (default false) also sends the statement itself,
  with every string and number replaced by `?`. Each project has its own server-side setting that
  can stop the statement being stored regardless of this flag; the names are still kept.

## 0.10.2

- Documentation only: the README and package description now describe ForgeOps as a hosted service, link to getforgeops.net, and show the real host in the connection string example instead of a placeholder. No code changes.

## 0.10.1

- Sidekiq job failures now report the real error. Sidekiq raises its own control-flow exception
  (`Sidekiq::JobRetry::Handled`, or `Skip` for a job with retries turned off) once it has scheduled
  a failed job's retry, and that wrapper, not the error inside it, was what reached ForgeOps, so
  every failing Sidekiq job, whatever went wrong, landed in the same opaque issue. The subscriber
  now unwraps it to its `#cause`. Confirmed against a real Sidekiq worker on 7.3 and 8.1. Among
  other things, this is what lets ForgeOps recognize a job class that was renamed or removed while
  jobs for it were still queued (an ActiveJob `UnknownJobClassError`, or a plain Sidekiq job's
  `NameError`), which previously arrived only as the wrapper.

## 0.10.0

- Real per-occurrence job/dependency failure tracking, feeding ForgeOps's own new cross-type
  project timeline: a job whose `perform` raised (detected via the existing `perform.active_job`
  subscription reading ActiveSupport::Notifications' own automatic `exception_object` payload key,
  no new hook needed) or an outbound `Net::HTTP` call that raised or came back 5xx (not 4xx) is
  now recorded individually, not just as an aggregate failure count. New `config.track_failures`
  (default true, independent of `track_performance`/`track_breadcrumbs`) and
  `config.failure_event_flush_interval` (default 60s). Known, documented gap: a connection-refused
  or DNS-failure error raised during `Net::HTTP.start`/`Net::HTTP.get_response`'s own connection
  setup (before `#request` itself ever runs) is invisible to this detection, the same pre-existing
  limitation that already silently applied to this SDK's outbound-HTTP breadcrumbs and timing;
  `Net::HTTP.new(...).request(...)` (no explicit `#start`) is unaffected, since Net::HTTP connects
  lazily inside `#request` itself in that case.

## 0.9.0

- Performance percentiles: every `PerformanceSample` (controller/query/http timing) now carries a
  small latency histogram alongside its existing count/sum/max, so ForgeOps can compute approximate
  p50/p95/p99 per transaction instead of only a weighted average. No new config; this rides the
  existing `track_performance` flag and flush interval.
- Background job queue latency: the existing `perform.active_job` subscription now also records how
  long a job actually waited in its queue before starting (not how long it took to run), as a new
  `job_latency` performance-sample kind grouped by queue name. Nil for a job run via `perform_now`,
  which never goes through `enqueue` at all.
- Database connection pool utilization: a new automatic reporter (matching the existing Sidekiq/
  Solid Queue/Puma stats reporters' own shape) periodically captures this process's own ActiveRecord
  connection pool size/busy/waiting counts as infrastructure metrics, polled on the same
  `config.gauge_poll_interval` those reporters already use.

## 0.8.0

- Breadcrumbs: a trail of SQL queries, controller actions, and outbound `Net::HTTP` calls leading
  up to an error, recorded automatically (on by default, same as every other automatic
  instrumentation this gem does; opt out with `config.track_breadcrumbs = false`, or tune
  `config.max_breadcrumbs`, default 30). `ForgeOpsTracker.add_breadcrumb(message, category:,
  level:, data:)` adds your own, regardless of whether the automatic sources are on, and works
  outside a request entirely too (a background job, a console session). Unlike the affected user,
  a breadcrumb's message/data is scrubbed for likely PII.

## 0.7.0

- Automatically associates a reported error with the current signed-in user, for any Warden-based
  auth setup (Devise included; Devise just mounts Warden automatically, this isn't Devise-
  specific). On by default, same as every other automatic instrumentation this gem does; opt out
  with `config.track_current_user = false`. `ForgeOpsTracker.set_user(id:, email:, username:)`
  manually sets or overrides it, for a custom auth setup or outside a request entirely (a
  background job, a console session).

## 0.6.0

- Performance monitoring now also covers database queries (`sql.active_record`, bucketed by
  Rails' own query name, never raw SQL text), background jobs (`perform.active_job`, any backend,
  Solid Queue included, plus raw Sidekiq workers via a server middleware, deduplicated against
  jobs dispatched through Active Job), and outbound `Net::HTTP` calls, alongside the existing
  controller/action timing. Each shows up as its own `kind` on the same `performance` dashboard
  dataset. Also reports Sidekiq's, Solid Queue's, and Puma's own operational gauges (queue depth,
  worker/dispatcher counts, Puma's thread pool) as infrastructure metrics on a periodic timer
  (`config.gauge_poll_interval`, default 60 seconds), whenever the corresponding library is
  already loaded. All on the same `track_performance` flag as before; no new flags to opt into.

## 0.5.0

- Every reported event now carries `sdk_name` ("ruby"), so a project's language on the ForgeOps
  dashboard auto-detects from whichever SDK is actually reporting into it, rather than staying
  stuck on whatever it was created with. Never overrides a language picked by hand in project
  settings.

## 0.4.0

- Session tracking (release health): every request is now counted as a session, crash-free unless
  an unhandled exception actually escapes it, so the ForgeOps dashboard can show a crash-free rate
  per release rather than only ever hearing about the requests that broke. Counted in-process and
  flushed as a small periodic aggregate (`config.session_flush_interval`, default 60 seconds) on
  its own background thread, not one network call per request. On by default, the same as error
  tracking itself (`config.track_sessions = false` opts out); requires a ForgeOps plan that
  includes release health, checked server-side on every flush.

## 0.3.0

- Source context capture: each in-app backtrace frame can now carry the 5 lines of source on
  either side of the culprit line, read straight off disk at raise-time, so an issue's detail page
  can show the actual code that broke, not just a file:line:method reference. On by default
  (`config.capture_source_context = false` opts out), but the real, durable protection is a
  per-project setting on the ForgeOps server, not this flag: turning it off there stops the server
  from ever storing captured source lines for that project again, regardless of what any individual
  app's own local setting is still set to. Never applies to a frame outside your app's own code,
  and fails silently for any file that can't be read.

## 0.2.0

- Client-side PII scrubbing: payloads are scrubbed (email addresses, formatted SSNs/credit
  cards, known API key/token formats, and any field whose name suggests a secret) before they
  ever leave the host app's process, not just on arrival at the ForgeOps server. On by default;
  `config.scrub_pii = false` opts out.

## 0.1.0

- Initial release: a Railtie subscribing to `Rails.error`, so unhandled exceptions and job
  failures report automatically with no further wiring. Delivery runs on a small background
  thread with a bounded queue and short HTTP timeouts; every failure mode (network errors,
  timeouts, a full queue, a malformed DSN) is caught and dropped rather than raised, so a broken
  or unreachable tracker can never take down the host app.
