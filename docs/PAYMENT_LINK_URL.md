# Payment link URL and "undefined" / loading forever

When you open the payment link and the page keeps loading or you see API calls to `http://localhost/undefined/api/v1/payment/reference/...`, the cause is usually one of these.

## 1. `undefined` in the API path

The **payments page** (e.g. payram-frontend `/payments`) needs two query params:

- **`reference_id`** – payment reference (UUID)
- **`host`** – backend API base URL (e.g. `http://localhost:8080`)

It calls the API as: `host + "/api/v1/payment/reference/" + reference_id`.  
If **`host`** is missing from the URL, the variable is `undefined`, so the browser requests:

`http://<current-origin>/undefined/api/v1/payment/reference/...`

So the page never gets payment data and keeps loading.

**Fix:** Open the link **exactly as returned** by the backend. It must look like:

```text
http://<frontend>/payments?reference_id=<uuid>&host=http://localhost:8080
```

with a **real ampersand (`&`)** between `reference_id` and `host`. Do not remove `host`, and do not change `&` to something else.

## 2. `\u0026` instead of `&` (broken link)

If the link was copied from JSON, a terminal, or some tools, the ampersand is sometimes turned into the literal characters **`\u0026`** (or `%5Cu0026` when encoded). Then:

- The browser treats `reference_id` as the whole string: `uuid\u0026host=http://localhost:8080`
- There is no separate **`host`** param → `host` is `undefined` → same broken API calls as above.
- The path can also look like: `.../reference/<uuid>/u0026host=...`

**Fix:** Use a link that has a **real `&`** between params, for example:

```text
http://localhost/payments?reference_id=db68046b-e8bf-48fb-a8fb-bca72bd96e1c&host=http://localhost:8080
```

If you only have a broken link, fix it by replacing `\u0026` or `%5Cu0026` with `&`.

## 3. Frontend and backend URLs

- **Frontend** (where the payment page is served): e.g. `http://localhost` (port 80) – set by `payram.frontend`.
- **Backend** (API): e.g. `http://localhost:8080` – set by `payram.backend` and passed in the link as **`host`**.

The payment page runs in the browser and must call the **backend** using the **`host`** param. So the link must always include `&host=<backend_url>`.

## Summary

- Open the payment URL **as returned** (with `reference_id` and `host` and a real `&`).
- If the page loads forever or you see `undefined` in API calls, check that the URL in the address bar has **`&host=http://...`** and that the ampersand is not `\u0026` or `%5Cu0026`.
