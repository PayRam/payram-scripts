# payram.frontend and payram.backend configuration

## Are they required?

Yes. The backend **requires** `payram.frontend` and `payram.backend` in the `configurations` table before it will create a payment request. If either is missing, `CreateNewPaymentRequest` returns an error and the API responds with 500.

- **payment_service_impl.go**: `GetConfigurationByKey("payram.frontend")` and `GetConfigurationByKey("payram.backend")` are called at the start of `CreateNewPaymentRequest`; on error, the function returns (no payment is created).

## Where are they set in the normal (UI) flow?

**There is no migration and no seed** that inserts these keys. The configuration seed (`configuration_seed.go`) does not define `payram.frontend` or `payram.backend`.

They are set **only** in the auth layer, and **only from the HTTP request**:

- **File**: `internal/api/handlers/auth_handler.go`
- **When**: On every **Signup** and **Signin** request, the handler calls `updateURLs(c)` before processing auth.
- **How**:
  - **payram.frontend**: From `GetFrontendBaseURL(c.Request)` → uses the **Origin** header, then **Referer**. So when a user signs in from the PayRam web UI (e.g. `https://app.payram.com`), the browser sends `Origin: https://app.payram.com` and the backend creates/updates `payram.frontend`.
  - **payram.backend**: From `GetBackendBaseURL(c.Request)` → derived from the request (scheme + host + port, e.g. `https://api.payram.com:8443`). So the backend URL is inferred from the same request.

So in the normal flow:

1. User opens the PayRam **web UI** in a browser.
2. User signs in or signs up → browser sends POST to the backend with `Origin` (and optionally `Referer`) and the request target as backend.
3. `updateURLs(c)` runs and creates/updates both configs from that single request.
4. No form asks for “frontend URL” or “backend URL”; the UI never exposes this. It is implicit.

## Why headless breaks

When you use the headless script (or any non-browser client):

- There is no **Origin** or **Referer** from a browser, so `GetFrontendBaseURL` returns `""`.
- The backend only creates `payram.frontend` when `desiredFrontend != ""`, so **payram.frontend is never created** when auth is done via curl/headless.
- **payram.backend** may be created from the request Host (e.g. `http://localhost:8080`), but that’s not guaranteed in all environments.

So after headless signin/signup, one or both configs can be missing → payment creation returns 500.

## What the headless script does

The headless script’s **ensure-config** step (and the automatic config check before creating a payment link) is a **workaround for the headless case only**:

- When the API base URL is localhost (or 127.0.0.1), it tries to create `payram.frontend` and `payram.backend` via the configuration API if they are missing.
- This mirrors what the auth handler would have done if the request had come from a browser with an Origin header.

So:

- **Normal flow**: No extra step; configs are set implicitly on first signin/signup from the UI. No documentation in the UI is needed because the user never provides these values.
- **Headless flow**: Configs are not set by auth, so the script explicitly seeds them when talking to a local API.

If you want the same behavior without the headless workaround, the backend would need to either:

- Make these configs optional for payment creation (e.g. use defaults or empty when missing), or
- Seed or document them (e.g. migration/seed or env-based defaults) so they always exist.
