# Kurako patch

- Upstream: `desktop_webview_window` 0.3.2
- License: Apache-2.0, preserved from upstream.

## Changes

1. Never print MethodChannel arguments on handler errors. OAuth callbacks and
   JavaScript calls can contain authorization codes, form bodies, tokens, and
   the client secret.
2. Cancel every `NewWindowRequested` event instead of navigating the current
   login document to a script-opened URL. The Dart navigation whitelist cannot
   observe this event.
3. Make `Webview.close()` await the native close method so callers can bound
   cleanup and detect a failed method-channel close.

No other platform or business behavior is changed.
