# 07 — Open a Red Hat support case

Open a support case against the Red Hat Customer Portal / Case Management API.
This is the one task in the repo that is **not infrastructure at all** — it is an
external ticket — so it is modeled as a side-effect (`null_resource` +
`local-exec`) and nothing more.

## What Terraform can and cannot do here

| | |
| --- | --- |
| **Can** | fire the API call deterministically, with credentials kept in a `sensitive` variable and the request body in state-visible (but non-secret) variables |
| **Cannot** | know when the case is resolved, attach files, or track the case lifecycle. The case is owned by the portal; Terraform's job ends when the POST returns |

## The shape of the call

```
POST <case_base_url>
Authorization: Bearer <rh_token>
Content-Type: application/json
{ "subject": ..., "description": ..., "product_id": ... }
```

**Confirm the base URL, required fields, and product IDs against the current
Customer Portal Integration Guide before relying on this.** The portal's API
surface (paths, required fields, token type) has changed across releases, and
`product_id` values are account/product-specific — the values in `main.tf` are
placeholders, not a catalog. Some portals also expose case creation only through
an SSO-interactive flow rather than a plain bearer POST; if yours does, this
module is the place to put that one-off call, but the exact mechanism must come
from the current integration docs.

## Why it is still a `null_resource`

The `triggers` block keys on `subject` + `description`, so Terraform only re-fires
the call when you actually change the case content — and because a support case
is a one-way action, **a re-`apply` with the same values does not open a
duplicate** (the resource is already in state). That is the closest Terraform
gets to idempotency for an action it does not own; if the portal returns a case
ID, store it in state via `local-exec` + `terraform` state or a file for
correlation.

## Validation

`terraform init` + `terraform validate` pass (only `hashicorp/null` is involved).
A live `apply` needs a valid `rh_token` and a confirmed `case_base_url`.

## Related

- [`../docs/00-prerequisites.md`](../docs/00-prerequisites.md) — where `rh_token` comes from
