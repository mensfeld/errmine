# Errmine changelog

## 0.2.0 (2025-12-24)
- [Feature] Add app name to issue title for easy identification when multiple apps report to the same Redmine project.
- [Feature] Include app_name in checksum calculation so same errors in different apps create separate issues.
- [Feature] Add `Errmine.create_issue` method for creating custom Redmine issues with arbitrary subject, description, tracker, project, and tags.
- [Feature] Add tags support via `tag_list` parameter for both exception reporting and custom issues.
- [Feature] Add `default_tags` configuration option for tags applied to all issues.
- [Maintenance] Update actions/checkout to v6 in CI.

## 0.1.1 (2025-12-23)
- [Fix] Fix file permissions for gem packaging.
- [Fix] Fix gemspec metadata duplicate URI warning.

## 0.1.0 (2025-12-23)

Initial release of Errmine - dead simple exception tracking for Redmine.

- [Feature] Automatic exception tracking to Redmine via REST API.
- [Feature] Issue deduplication using 8-character MD5 checksums based on exception class, message, and first application backtrace line.
- [Feature] Occurrence counter in issue subject (`[checksum][count] ExceptionClass: message`).
- [Feature] Rate limiting with configurable cooldown to prevent Redmine flooding.
- [Feature] Rails 7+ Error Reporting API integration via Railtie.
- [Feature] Rack middleware for exception handling in all Ruby web applications.
- [Feature] Manual notification API with custom context support.
- [Feature] Environment variable configuration (`ERRMINE_REDMINE_URL`, `ERRMINE_API_KEY`, `ERRMINE_PROJECT`, `ERRMINE_APP_NAME`).
- [Feature] Thread-safe in-memory cache with automatic cleanup.
- [Feature] Fail-safe error handling - never crashes your application.
- [Feature] Zero runtime dependencies - uses only Ruby stdlib.
