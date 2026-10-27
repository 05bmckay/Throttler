# Dependency and credential review — September 4, 2026

## October 27 recovery-fix release review

The required release audit found the September reviews expired and new advisories for Decimal, Mint, and Plug.Crypto. The recovery-fix branch updates Cowboy to 2.20.0, Cowlib to 2.21.0, Decimal to 3.2.0, Mint to 1.11.0, Plug.Crypto to 2.2.1, and their compatible Castore/HPAX/Ranch dependencies. The updated OSV scan retains only EEF-CVE-2026-43966; the other eight reported matches no longer apply to these versions.

EEF-CVE-2026-43966 was re-reviewed against the installed Cowlib 2.21.0 / Cowboy 2.20.0 sources on October 27. No `cow_http_struct_hd` or `wt_protocol` calls were found in `lib/`, `config/`, or the active Finch, Mint, Plug, Plug.Cowboy, Phoenix, and Websock.Adapter Elixir sources. `cowboy_http:validate_response_headers/2` still defaults to `error_terminate` and rejects CR/LF; HTTP/2 uses the same validation. Application configuration does not override `invalid_response_headers`. The advisory's server-side mitigation therefore remains in place. This is a version-scoped applicability review, not a claim that Cowlib's encoder is patched; it expires November 26 and must be revisited on HTTP-stack/configuration changes. The earlier reviews below are historical.

OSV matched ten vulnerable locked packages before remediation. The candidate updates Phoenix to 1.7.24, Plug to 1.20.3, Plug.Cowboy to 2.9.0, Cowboy to 2.18.0, Mint to 1.10.0, Postgrex to 0.22.4, Decimal to 3.1.1, and their compatible dependency closure. Updating the AppSignal integration removes Hackney and its dependency tree. JSON views retain `phoenix_view`; no UI migration is required.

The final 47-package scan has three remaining Cowlib 2.19.0 matches. Their CNA records list no patched Hex version. These remain visible in `dependency-audit.json`, with version-scoped applicability reviews that expire October 4. CI fails on any unreviewed match or expired exception. `mix hex.audit` checks retired packages and is not a vulnerability scan.

| Advisory | Application exposure review |
| --- | --- |
| [CVE-2026-43966](https://cna.erlef.org/cves/CVE-2026-43966.html) | Structured-header encoder CRLF. No application or active dependency call sites for `cow_http_struct_hd` encoding were found. Cowboy 2.18's `invalid_response_headers` defaults to `error_terminate`, providing the CNA's server mitigation. Do not override it to `ignore`. |
| [CVE-2026-43969](https://cna.erlef.org/cves/CVE-2026-43969.html) | Client Cookie encoder injection. No calls to `cow_cookie:cookie/1` were found in the app or active HTTP clients. Finch/Mint sends JSON/form requests with application-controlled headers and no Cookie header. Plug's signed server session uses the separate Set-Cookie path. |
| [CVE-2026-43971](https://cna.erlef.org/cves/CVE-2026-43971.html) | Link header builder injection. No calls to `cow_link:link/1` were found in the app or active dependencies; the app does not emit Link headers or round-trip user-supplied Link data. |

This is a reviewed lack of exposure in this candidate, not a claim that Cowlib is patched. Re-review before adding header builders, client cookies, browser assets, or changing the HTTP stack. The scanner keeps exact package/version/Cowboy requirements and the review deadline in `dependency-exceptions.json`.

Credential controls: production verifies database certificates and hostnames; token metadata accepts only approved non-secret fields; credentials remain in AES-GCM encrypted columns; OAuth refreshes hold a database row lock; config routes require a constant-time checked bearer credential. Routine HTTP/token logs are reduced. Supervisor progress reports and decryption exception details are disabled to avoid exposing connection or token material.

The migration removes live metadata copies, but historical database backups and any prior exported data may retain them. At rollout, inventory access to those copies and rotate/re-authorize affected credentials if exposure is established. Preserve the current encryption key; changing it without a re-encryption plan makes stored tokens unreadable. A broad database allowlist was observed in the baseline: restrict external access during release operations after identifying legitimate clients. Neither credentials nor network policy have been changed in production during candidate preparation.
