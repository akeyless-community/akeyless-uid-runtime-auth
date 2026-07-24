# Runtime Secret Retrieval with Akeyless Universal Identity

Authenticate an on-premises application server to Akeyless at runtime and
retrieve secrets, with **no human login and no long-lived API key stored on the
host**. A one-time bootstrap token is planted on the server, a systemd timer
self-rotates it, and any token copied off the host stops working at the next
rotation. A reference .NET 8 application retrieves a secret by shelling out to
the Akeyless CLI and holds no credential of its own.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [What This Solves](#what-this-solves)
3. [How It Works](#how-it-works)
4. [Prerequisites](#prerequisites)
5. [Repository Layout](#repository-layout)
6. [Step 1 - Bootstrap Akeyless (admin, one time)](#step-1--bootstrap-akeyless-admin-one-time)
7. [Step 2 - Plant the Token and Configure the Host](#step-2--plant-the-token-and-configure-the-host)
8. [Step 3 - Install the Rotation Timer](#step-3--install-the-rotation-timer)
9. [Step 4 - Run the Application](#step-4--run-the-application)
10. [Step 5 - Validate the Anti-Theft Property](#step-5--validate-the-anti-theft-property)
11. [Operations Guide](#operations-guide)
12. [Troubleshooting](#troubleshooting)
13. [Security Model and Limitations](#security-model-and-limitations)

---

## The Problem

An application running on an on-premises server needs to read secrets from
Akeyless at runtime. The server has no cloud IAM identity, no Kubernetes service
account, and no other platform-attested identity to present. The two common
fallbacks are both unacceptable:

- **A human SAML login.** Interactive authentication cannot be part of an
  unattended service that starts on boot and runs continuously.

- **A static API key on disk.** An access key written to a config file or
  environment variable is a permanent credential. If it leaks, it is valid until
  someone notices and revokes it, and nothing in the system signals that it was
  copied.

The requirement is a machine identity that authenticates without a human, without
a permanent secret at rest, and in a way that makes credential theft detectable.

## What This Solves

Akeyless **Universal Identity** issues a short-lived child token that the host
rotates on a schedule. This repository provides a complete, working reference:

- A bootstrap script that creates the auth method, a least-privilege role, and
  the first token.
- A rotation script and systemd timer that keep the token fresh and atomically
  replace it on disk.
- A .NET 8 console application that retrieves a secret through the Akeyless CLI
  and contains no credential in its source, configuration, or environment.

The property that makes this worth doing over a static key: **a token copied off
the host is only valid until the next rotation, and its reuse fails
authentication and is recorded in the Akeyless audit log.**

## How It Works

```
  Admin workstation                Application host
  -----------------                ----------------
  akeyless (admin)                 systemd timer ---> rotate-uid-token.sh
        |                                                    |
        | uid-generate-token                                 | uid-rotate-token
        v                                                    v
   bootstrap token  ---- copied once ---->   ~/.akeyless-uid/token/uid-token (0600)
                                                             ^
                                                             | reads current token
                                                     .NET app (SecretConsumer)
                                                             |
                                                             | akeyless get-secret-value --uid-token ...
                                                             v
                                                     secret value returned
```

1. An admin runs the bootstrap once and generates a single child token.
2. That token is copied to the host one time and stored `0600`.
3. A systemd timer rotates the token on an interval shorter than its TTL. Each
   rotation invalidates the previous token.
4. The application reads the current token at call time and asks the CLI for the
   secret. It never sees an access key.

## Prerequisites

| Requirement | Notes |
|---|---|
| Akeyless CLI | On both the admin workstation and the host. `akeyless --version`. |
| Admin profile | An existing Akeyless CLI profile with permission to create auth methods, roles, and secrets. Used only in Step 1. |
| Gateway URL | The Akeyless gateway your host reaches, e.g. `https://your-gateway.example.com`. |
| .NET 8 SDK | On the host, to build and run the reference application. |
| systemd (user) | For the rotation timer. A root/system unit works equally well with minor path changes. |

## Repository Layout

```
.
|-- bootstrap/
|   `-- setup-akeyless.sh          # admin one-time: auth method, role, secret, first token
|-- host/
|   |-- rotate-uid-token.sh        # reads current token, rotates, atomically replaces the file
|   |-- install-timer.sh           # installs the script + systemd user units
|   `-- systemd/
|       |-- akeyless-uid-rotate.service
|       `-- akeyless-uid-rotate.timer
|-- app/
|   |-- Program.cs                 # .NET 8 app; shells out to the CLI, holds no credential
|   `-- SecretConsumer.csproj
`-- README.md
```

## Step 1 - Bootstrap Akeyless (admin, one time)

From a workstation authenticated as an Akeyless admin, edit the variables at the
top of `bootstrap/setup-akeyless.sh` to match your environment, then run it:

```bash
ADMIN_PROFILE=admin \
GATEWAY_URL=https://your-gateway.example.com \
  ./bootstrap/setup-akeyless.sh
```

This creates:

- a Universal Identity auth method (`/demo/uid-auth`) with a 60-minute token TTL
  and inheritance denied,
- a role (`/demo/reader`) with read+list on `/demo/*`, associated to the auth
  method,
- a demo secret (`/demo/db-password`),
- and the first child token, written to `./uid-token` (`0600`).

The script prints the auth method **access id** and the next steps. Note the
access id; you need it in Step 2.

## Step 2 - Plant the Token and Configure the Host

Copy the bootstrap token to the host once, into the location the timer and app
expect:

```bash
install -d -m 700 ~/.akeyless-uid/token
install -m 600 uid-token ~/.akeyless-uid/token/uid-token
```

Configure a CLI profile on the host that names the auth method. It stores the
access id and auth type only, **never a key**:

```bash
akeyless configure --profile app-uid \
  --access-id <UID_ACCESS_ID> \
  --access-type universal_identity \
  --gateway-url https://your-gateway.example.com
```

## Step 3 - Install the Rotation Timer

From the `host/` directory on the server, as the service account that owns the
token:

```bash
./host/install-timer.sh
```

This installs `rotate-uid-token.sh` to `~/.akeyless-uid/`, installs the systemd
user units, and enables the timer. The timer runs the first rotation two minutes
after start and every 15 minutes thereafter. Confirm the schedule:

```bash
systemctl --user list-timers akeyless-uid-rotate.timer
journalctl --user -u akeyless-uid-rotate.service -n 20
```

## Step 4 - Run the Application

```bash
cd app
dotnet run -c Release
```

Expected output:

```
Retrieved secret '/demo/db-password' from Akeyless.
Value: replace-me-in-your-environment
No access key or long-lived credential was used or stored by this application.
```

The application reads the current token from `~/.akeyless-uid/token/uid-token`
and runs `akeyless get-secret-value --name /demo/db-password --profile app-uid
--uid-token <token>`. Override the secret path with an argument or the
`SECRET_NAME` environment variable.

## Step 5 - Validate the Anti-Theft Property

This is the test that distinguishes Universal Identity from a static API key.
Capture a token, force a rotation, then try to reuse the captured token:

```bash
STALE="$(cat ~/.akeyless-uid/token/uid-token)"     # attacker copies the token
~/.akeyless-uid/rotate-uid-token.sh                # timer rotates (simulated here)

# the fresh token still works:
cd app && dotnet run -c Release

# the captured token is now rejected:
akeyless get-secret-value --name /demo/db-password --profile app-uid --uid-token "$STALE"
```

The last command returns `401 Unauthorized / AuthenticationFailed`, and the
attempt appears in the Akeyless audit log with a session id you can search.

## Operations Guide

| Task | How |
|---|---|
| Change the rotation interval | Edit `OnUnitActiveSec` in `akeyless-uid-rotate.timer`, keep it well under the auth method's jwt-ttl, then `systemctl --user daemon-reload && systemctl --user restart akeyless-uid-rotate.timer`. |
| Change the token TTL | Recreate the auth method with a different `--jwt-ttl`, or update it, and make sure the rotation interval stays shorter. |
| Add a secret the app can read | Create it under the role's path prefix (`/demo/*`). No host or app change. |
| Rotate the demo secret's value | Change it in Akeyless. The next app run reads the new value. |
| Recover from a missed rotation | If the token expired before rotation, generate a new bootstrap token as in Step 1 and replant it as in Step 2. |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `UID token file not found` | The timer has not run yet, or the token was not planted. Run `~/.akeyless-uid/rotate-uid-token.sh` once, or replant the bootstrap token. |
| `401 AuthenticationFailed` on every call | The on-disk token expired, was already rotated elsewhere, or the interval exceeded the TTL. Replant a fresh bootstrap token and shorten the interval. |
| `undefined option --profile` on rotate | `uid-rotate-token` routes via the token itself and takes no `--profile`; use the script as provided. |
| App prints an access key error | The profile was configured with a static key. Reconfigure with `--access-type universal_identity` and no key. |

## Security Model and Limitations

Universal Identity does not remove secret material from the host. It replaces a
**permanent** credential with a **short-lived, self-rotating** one and makes
theft detectable through rotation and the audit log. That is a large improvement
over a static API key, and it is the right model for a server with no
platform-attested identity.

It is not the right model if your requirement is that **no** secret material ever
resides on the host. That requires an attested identity the platform issues and
verifies, such as cloud IAM, a Kubernetes service account, or SPIFFE/SPIRE. A
bare on-premises server has none of these, which is exactly the gap Universal
Identity fills.
