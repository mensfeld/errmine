<p align="center">
  <img src="misc/logo.png" alt="Errmine" width="300"/>
</p>

# Errmine

[![Build Status](https://github.com/mensfeld/errmine/workflows/ci/badge.svg)](https://github.com/mensfeld/errmine/actions?query=workflow%3Aci)
[![Gem Version](https://badge.fury.io/rb/errmine.svg)](http://badge.fury.io/rb/errmine)

Dead simple, zero-dependency exception tracking for Redmine.

Errmine automatically creates and updates Redmine issues from Ruby/Rails exceptions. When an error occurs, it creates a new issue. When the same error occurs again, it increments a counter and adds a journal note instead of creating duplicates.

```
[a1b2c3d4][47] NoMethodError: undefined method 'foo' for nil...
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
- Occurrence counting shows error frequency at a glance

**vs. Rolling your own**
- Zero dependencies - uses only Ruby stdlib
- Handles edge cases: rate limiting, timeouts, thread safety, fail-safe error handling
- Works out of the box with Rails 7+ Error Reporting API

## Features

- **Zero dependencies** - Uses only Ruby stdlib (net/http, json, digest, uri)
- **Automatic deduplication** - Same errors update existing issues instead of creating duplicates
- **Rate limiting** - Prevents flooding Redmine during error loops
- **Rails integration** - Works with Rails 7+ Error Reporting API or as Rack middleware
- **Thread-safe** - Safe to use in multi-threaded environments
- **Fail-safe** - Never crashes your application, logs errors to stderr

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
| `enabled` | `true` | Enable/disable notifications |
| `cooldown` | `300` | Seconds between same-error notifications |

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
    custom_field: 'any value'
  })
  raise
end
```

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

### Disabling Notifications

```ruby
Errmine.configure do |config|
  config.enabled = Rails.env.production?
end
```

## How It Works

### Checksum Generation

Each exception gets an 8-character MD5 checksum based on:
- Exception class name
- Exception message
- First application backtrace line (containing `/app/`)

```
MD5("NoMethodError:undefined method 'foo':app/controllers/users_controller.rb:45")[0..7]
# => "a1b2c3d4"
```

### Deduplication

1. Search Redmine for open issues containing `[{checksum}]` in the subject
2. If found: increment counter, add journal note with timestamp and backtrace
3. If not found: create new issue

### Rate Limiting

To prevent flooding Redmine during error loops:

- Each checksum is cached with its last occurrence time
- Same error won't hit Redmine more than once per cooldown period (default: 5 minutes)
- Cache is automatically cleaned when it exceeds 500 entries

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
[{checksum}][{count}] {ExceptionClass}: {truncated message}
```

Example: `[a1b2c3d4][47] NoMethodError: undefined method 'foo' for nil...`

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
