<p align="center">
  <img src="misc/logo.png" alt="Errmine" width="600"/>
</p>

# Errmine

[![Gem Version](https://badge.fury.io/rb/errmine.svg)](http://badge.fury.io/rb/errmine)

Dead simple, zero-dependency exception tracking for Redmine.

Errmine automatically creates and updates Redmine issues from Ruby/Rails exceptions. When an error occurs, it creates a new issue. When the same error occurs again after the cooldown, it increments a counter and adds a journal note instead of creating duplicates.

```
[my-app][a1b2c3d4][47] NoMethodError: undefined method 'foo' for nil...
```

## Why Errmine?

If you already use Redmine for project management, Errmine lets you track production errors without adding another service to your stack.

**vs. Sentry, Honeybadger, Airbrake, etc.**
- No external service, no monthly fees, no data leaving your infrastructure
- Errors live alongside your tasks and documentation in Redmine
- No new UI to learn - just Redmine issues

**vs. Exception Notification gem**
- Automatic deduplication - same error updates existing issue instead of creating duplicates
- Rate limiting prevents inbox/Redmine flooding during error storms
- Occurrence counter in the subject - counts the reports that passed the cooldown, not every occurrence (at most one per error per cooldown period in each process)

**vs. Rolling your own**
- Zero dependencies - uses only Ruby stdlib
- Handles edge cases: rate limiting, timeouts, thread safety, fail-safe error handling (reporting is synchronous, see [Synchronous Reporting](#synchronous-reporting))
- Works out of the box with Rails 7+ Error Reporting API

## Features

- **Zero dependencies** - Uses only Ruby stdlib (net/http, json, digest, uri)
- **Automatic deduplication** - Same errors update existing issues instead of creating duplicates (no lock across processes, see [Deduplication](#deduplication))
- **Rate limiting** - Prevents flooding Redmine during error loops
- **Rails integration** - Works with Rails 7+ Error Reporting API or as Rack middleware
- **Thread-safe** - Safe to use in multi-threaded environments
- **Fail-safe** - Never crashes your application, logs errors to stderr (reporting still blocks the caller, see [Synchronous Reporting](#synchronous-reporting))

## Installation

Add to your Gemfile:

```ruby
gem 'errmine'
```

Then run:

```bash
bundle install
```

## Configuration

### Environment Variables

Errmine reads these environment variables as defaults:

- `ERRMINE_REDMINE_URL` - Redmine server URL
- `ERRMINE_API_KEY` - API key for authentication
- `ERRMINE_PROJECT` - Project identifier (default: `'bug-tracker'`)
- `ERRMINE_APP_NAME` - Application name (default: `'unknown'`)

### Rails

Create an initializer:

```ruby
# config/initializers/errmine.rb
Errmine.configure do |config|
  config.redmine_url = ENV.fetch('REDMINE_URL')
  config.api_key     = ENV.fetch('REDMINE_API_KEY')
  config.project_id  = 'my-project'
  config.tracker_id  = 1                    # Default: 1 (Bug)
  config.app_name    = Rails.application.class.module_parent_name
  config.cooldown    = 300                  # Default: 300 seconds
end
```

### Plain Ruby

```ruby
require 'errmine'

Errmine.configure do |config|
  config.redmine_url = 'https://redmine.example.com'
  config.api_key     = 'your-redmine-api-key'
  config.project_id  = 'my-project'
end
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `redmine_url` | `ENV['ERRMINE_REDMINE_URL']` | Redmine server URL (required) |
| `api_key` | `ENV['ERRMINE_API_KEY']` | API key for authentication (required) |
| `project_id` | `ENV['ERRMINE_PROJECT']` or `'bug-tracker'` | Redmine project identifier |
| `tracker_id` | `1` | Tracker ID (usually 1 = Bug) |
| `app_name` | `ENV['ERRMINE_APP_NAME']` or `'unknown'` | Application name shown in issues |
| `default_tags` | `[]` | Tags (array of strings) added to every issue Errmine creates |
| `enabled` | `true` | Enable/disable notifications and custom issues |
| `cooldown` | `300` | Seconds between same-error notifications (after a failed report, the next occurrence is reported after 60 seconds, or after the cooldown if it is shorter) |

## Usage

### Rails 7+ (Automatic)

Errmine automatically subscribes to Rails' error reporting API via a Railtie. Unhandled exceptions are reported automatically. No additional setup required.

### Rack Middleware

For all Rails versions or any Rack-based application:

```ruby
# config/application.rb (Rails)
config.middleware.use Errmine::Middleware

# or config.ru (Sinatra, etc.)
use Errmine::Middleware
```

The middleware captures request context (URL, HTTP method, user via Warden).

### Manual Notification

Report exceptions manually with custom context:

```ruby
begin
  risky_operation
rescue => e
  Errmine.notify(e, {
    url: request.url,
    user: current_user&.email,
    tags: ['checkout'],
    custom_field: 'any value'
  })
  raise
end
```

- `tags` is optional, an array of strings. When the report creates a new issue, the issue gets `default_tags` plus these tags, without duplicates
- The issue description also gets a `**Tags:**` line with these tags as a Ruby array, for example `**Tags:** ["checkout"]` (without `default_tags`)
- When a report that passes the cooldown finds an open issue for the error, it updates that issue and ignores `tags`: Errmine adds no tags to the issue and no tags line to the journal note

### rescue_from in Controllers

```ruby
class ApplicationController < ActionController::Base
  rescue_from StandardError do |e|
    Errmine.notify(e, {
      url: request.url,
      user: current_user&.email
    })
    raise e
  end
end
```

### Custom Issues

Create a Redmine issue with your own subject and description:

```ruby
Errmine.create_issue(
  subject: 'Nightly import failed',
  description: 'The import stopped at row 1200.',
  tags: ['import']
)
```

- `subject` and `description` are required; the description uses Textile format
- `project_id` and `tracker_id` are optional and default to the configured values
- `tags` is optional; the issue gets `default_tags` plus these tags, without duplicates
- When `enabled` is `false`, it creates no issue and returns `nil`
- Otherwise each call creates a new issue with one HTTP request, in the calling thread: no checksum, no deduplication, no cooldown
- Returns the created issue as a Hash (the `issue` object from Redmine's response), or `nil` when Errmine gets no created issue back (disabled, or the request or response failed). After a read timeout or an unreadable response, Redmine can still have created the issue. Errmine logs its own failures to stderr and does not raise them

### Disabling Notifications

```ruby
Errmine.configure do |config|
  config.enabled = Rails.env.production?
end
```

## How It Works

### Checksum Generation

Each exception gets an 8-character MD5 checksum based on:
- Application name (`app_name`)
- Exception class name
- Exception message
- First application backtrace line (containing `/app/`), or the first backtrace line if none contains `/app/`

The same error in two applications with different `app_name` values creates two separate issues.

```
MD5("my-app:NoMethodError:undefined method 'foo':app/controllers/users_controller.rb:45")[0..7]
# => "a1b2c3d4"
```

### Deduplication

1. Search Redmine for open issues containing `[{checksum}]` in the subject
2. If found: increment counter, add journal note with timestamp and backtrace
3. If not found: create new issue

The rate limit cache is per process, and the search and the create have no lock across processes. Two processes (for example, two web server workers) that report the same new error at the same time can both find no issue and create two issues.

### Rate Limiting

To prevent flooding Redmine during error loops:

- Each checksum is cached with the time of its last report that passed the cooldown; reports inside the cooldown are dropped and do not restart it
- Same error won't hit Redmine more than once per cooldown period (default: 5 minutes) in each process, unless the report fails
- When a report fails (HTTP error status, timeout, connection error), Errmine logs one warning to stderr and does not resend that occurrence. The next occurrence of the same error after 60 seconds (or after the cooldown, if it is shorter) is reported, instead of being dropped for the whole cooldown. During a Redmine outage the same error can call Redmine once per 60 seconds or once per cooldown, whichever is shorter, in each process
- Cache is automatically cleaned when it exceeds 500 entries

### Synchronous Reporting

`Errmine.notify` runs in the thread that reports the error. This includes the Rack middleware and the Rails error subscriber, so the request or job waits until Errmine finishes.

- Each report that passes the cooldown makes up to 2 HTTP requests to Redmine: a search, then a create or an update
- Each request has a 5-second connect timeout (`CONNECT_TIMEOUT`) and a 10-second read timeout (`READ_TIMEOUT`)
- Errmine's own failures (timeouts, connection and HTTP errors) never raise into your application: Errmine logs them to stderr and `Errmine.notify` returns `nil`

## Redmine Setup

1. **Enable REST API**: Administration > Settings > API > Enable REST web service
2. **Create an API key**: My Account > API access key > Show/Reset
3. **Create a project** for error tracking (or use existing one)
4. **Permissions**: The API user needs:
   - View issues
   - Add issues
   - Edit issues
   - Add notes

## Issue Format

### Subject

```
[{app_name}][{checksum}][{count}] {ExceptionClass}: {truncated message}
```

Example: `[my-app][a1b2c3d4][47] NoMethodError: undefined method 'foo' for nil...`

### Description (Textile format)

```textile
**Exception:** @NoMethodError@
**Message:** undefined method 'foo' for nil:NilClass
**App:** my-app
**First seen:** 2025-01-15 10:30:00

**URL:** /users/123
**User:** user@example.com

h3. Backtrace

<pre>
app/controllers/users_controller.rb:45:in `show'
app/controllers/application_controller.rb:12:in `authenticate'
</pre>
```

### Journal Note (on subsequent occurrences)

```textile
Occurred again (*47x*) at 2025-01-15 10:35:00

URL: /users/456

<pre>
app/controllers/users_controller.rb:45:in `show'
</pre>
```

## License

MIT License. See [LICENSE](LICENSE) for details.
