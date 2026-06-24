# Hetha Organics

Hetha Organics is an organic grocery and dairy delivery business built around a
**daily subscription model**: customers prepay into a wallet, set up recurring
daily deliveries (e.g. milk every day), and the operations team generates a
delivery "run sheet" each day from the active subscriptions.

This folder contains the **two applications** that make up the platform, plus
shared documentation for the backend they both depend on.

```
Hetha/
├── Hetha_app/      Customer-facing app          (Flutter • Dart • Riverpod)
├── Hetha_admin/    Internal operations panel     (Next.js • React • TypeScript)
└── docs/           Shared backend & system docs  (Supabase / Postgres)
```

> **Note:** `Hetha_app` and `Hetha_admin` are **independent git repositories**.
> They are documented separately and can be cloned, built, and deployed on their
> own. The only thing they share is the **Supabase backend** — documented here
> at the top level so the two repos stay in sync with one source of truth.

---

## The two applications

| App | Audience | Stack | Docs |
|-----|----------|-------|------|
| **[Hetha_app](./Hetha_app/)** | Customers | Flutter (Android, iOS, Web, desktop), Riverpod, `supabase_flutter`, Razorpay | [README](./Hetha_app/README.md) · [Architecture](./Hetha_app/docs/ARCHITECTURE.md) |
| **[Hetha_admin](./Hetha_admin/)** | Internal staff | Next.js 16 (App Router), React 19, TypeScript, Tailwind 4, TanStack Query | [README](./Hetha_admin/README.md) · [Architecture](./Hetha_admin/docs/ARCHITECTURE.md) |

Both talk to the same Supabase project. The customer app uses the public
(anon) key and is constrained by Row-Level Security; the admin panel adds a
service-role path for privileged operations and an internal RBAC layer.

---

## How the pieces fit together

```
                ┌───────────────────────┐        ┌──────────────────────────┐
                │   Hetha_app (Flutter)  │        │  Hetha_admin (Next.js)   │
                │   customers            │        │  internal staff          │
                └───────────┬───────────┘        └────────────┬─────────────┘
                            │ anon key (RLS)                    │ anon key (RLS) +
                            │                                   │ service role (server only)
                            ▼                                   ▼
                ┌───────────────────────────────────────────────────────────┐
                │                    Supabase project                        │
                │                                                             │
                │  Auth   •   Postgres (25+ tables)   •   RLS policies        │
                │  RPCs (place_order, create_subscription, …)                 │
                │  Edge Functions (razorpay: create-order / verify-payment)   │
                └───────────────────────────────┬─────────────────────────────┘
                                                 │ HMAC-verified server-side
                                                 ▼
                                          ┌──────────────┐
                                          │   Razorpay   │
                                          └──────────────┘
```

See **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)** for the full system view
and **[docs/DATA_MODEL.md](./docs/DATA_MODEL.md)** for the database schema.

---

## Core domain concepts

A few concepts recur across both apps; understanding them makes the rest of the
code obvious.

- **Wallet (prepaid).** Each user has a `wallet_balance`. Subscriptions are paid
  for by daily wallet deductions, so the wallet must stay funded. One-time
  orders may also be paid from the wallet.
- **Subscription.** A recurring daily delivery for a set of products at a chosen
  address and frequency. A user may have up to **5 active subscriptions**, each
  with an optional `label` ("Home", "Parents", …).
- **3-day buffer rule.** When creating a subscription or paying for a one-time
  order from the wallet, the app reserves **3 days of total daily commitment** so
  upcoming subscription deliveries can't be starved by a single purchase.
- **Daily order / run sheet.** Each day, operations generates the list of
  deliveries by filtering active subscriptions through cutoff times, pauses,
  one-time modifications, and end dates, then snapshots each order. See
  [Hetha_admin/docs/daily_ops.md](./Hetha_admin/docs/daily_ops.md).
- **Snapshots.** Orders and subscriptions copy customer/address/product details
  into `snapshot_*` columns at creation time, so historical records stay
  accurate even if the source data changes later.
- **Delivery areas & pincodes.** Serviceability, cutoff times, and delivery
  frequency are defined per area; pincodes map customers to an area.

---

## Getting started

Each application has its own setup instructions — start there:

1. **Customer app:** [`Hetha_app/README.md`](./Hetha_app/README.md)
2. **Admin panel:** [`Hetha_admin/README.md`](./Hetha_admin/README.md)

Both require credentials for the shared Supabase project. They are **not**
interchangeable:

| App | Env file | Keys |
|-----|----------|------|
| `Hetha_app` | `.env` | `PROJECT_URL`, `PUBLISHABLE_KEY` |
| `Hetha_admin` | `.env.local` | `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` |

The Razorpay **secret** lives only in the Supabase Edge Function environment
(`key_secret`) and never ships in either client. See
[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md#payments).

---

## Documentation map

| Document | Scope |
|----------|-------|
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | System-wide architecture, auth, payments, data flow |
| [docs/DATA_MODEL.md](./docs/DATA_MODEL.md) | Shared Supabase schema, RPCs, edge functions |
| [Hetha_app/README.md](./Hetha_app/README.md) | Customer app: setup, run, build, structure |
| [Hetha_app/docs/ARCHITECTURE.md](./Hetha_app/docs/ARCHITECTURE.md) | Flutter layers, Riverpod, services |
| [Hetha_app/CONTRIBUTING.md](./Hetha_app/CONTRIBUTING.md) | App conventions & how to add features |
| [Hetha_admin/README.md](./Hetha_admin/README.md) | Admin panel: setup, run, build, structure |
| [Hetha_admin/docs/ARCHITECTURE.md](./Hetha_admin/docs/ARCHITECTURE.md) | Next.js layers, auth/RBAC, services, API |
| [Hetha_admin/CONTRIBUTING.md](./Hetha_admin/CONTRIBUTING.md) | Admin conventions & how to add features |
| `CHANGES_*.md` | Dated change logs of recent work |

---

## Change log

Day-by-day change notes live in the dated `CHANGES_YYYY-MM-DD.md` files in this
folder. They are the running history of feature work and fixes across both apps.