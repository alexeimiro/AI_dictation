# Putting the dictation server on a host

Two scripts put `server/main.ts` on a host and take it away again: `gcp.sh` (a small Google Cloud
VM) and `fly.sh` (Fly.io). Both start the same way: the server answers only the network test, so the
evening of measuring from Russian connections can decide which network the real server goes on.
Later the winner gets the project's variables with `env`, and the loser is deleted.

Nothing here runs without your accounts, and nothing is created before the script has printed what
it creates and what it costs, and you have typed `yes`.

## The order

1. Accounts: Google Cloud (a project with billing; the free trial's credit counts) and Fly.io (a
   payment method). Install the tools: `gcloud` (https://cloud.google.com/sdk/docs/install, then
   `gcloud auth login` and `gcloud config set project <id>`) and `flyctl` (`brew install flyctl`,
   then `fly auth login`).
2. Look first, change nothing:

   ```sh
   server/deploy/gcp.sh plan            # Finland; --region frankfurt, --size micro
   server/deploy/fly.sh plan            # Stockholm (Fly has no Finland); --region frankfurt
   ```

3. Create both. Each adds its address to `scripts/out/network_test/hosts.txt`:

   ```sh
   server/deploy/gcp.sh create
   server/deploy/fly.sh create
   ```

4. The evening (below), from home Wi-Fi and from each carrier on the iPhone's hotspot.
5. Delete the network that lost, so it stops billing: `server/deploy/fly.sh delete` or
   `server/deploy/gcp.sh delete`. Keep the runner-up only if you want a spare.

## The evening

One command per connection. It tests every host in the list and today's Supabase at the same time
(about 6 minutes), then prints the table for the whole evening:

```sh
scripts/network_test.sh home-wifi        # then switch the Mac to the iPhone's hotspot, VPN off:
scripts/network_test.sh beeline
scripts/network_test.sh mts
scripts/network_test.sh --report         # the table again, nothing run
```

`scripts/network_test.sh beeline --quick` is a one-minute check first, kept out of the evening's table.
A network passes on a connection when the test started, every ping came back, a 256 KB download
arrived whole (some Russian networks cut a connection after about 16 KB), and at least 95% of the
60-second streams ended with no silence over 2 s. It passes overall when it passes on every
connection. The lowest worst-connection round trip wins; the runner-up is the spare. Results stay
in `scripts/out/network_test/<date>/` (git-ignored), with the table in `table.txt`.

## What it costs

List prices read on the vendors' own pages on 2026-11-13, USD, for a 730-hour month:

| | a month | a day |
|---|---|---|
| Google Cloud e2-small, Finland: VM $13.46, 10 GB disk $1.10, static IPv4 $3.65, ~2 GB out $0.12 | $18.33 | $0.60 |
| Google Cloud e2-small, Frankfurt: $15.76 + $1.20 + $3.65 + $0.12 | $20.73 | $0.68 |
| Google Cloud e2-micro (1 GB), Finland / Frankfurt | $11.60 / $12.85 | $0.38 / $0.42 |
| Fly.io shared-cpu-1x 1 GB, Stockholm, shared IPv4 | $7.09 | $0.23 |
| Fly.io, Frankfurt | $7.88 | $0.26 |
| A dedicated IPv4 on Fly (`--dedicated-ipv4`) | +$2.00 | |

Sources: cloud.google.com/products/compute/pricing/general-purpose, /compute/disks-image-pricing,
/vpc/network-pricing; docs.fly.io/about/pricing. New Google Cloud accounts get $300 of credit and
pay nothing until they upgrade to a paid account. Fly waives a personal organization's bill under
$5 a month, so a day or two of testing costs nothing there. A stopped Google VM still pays for its
disk and reserved address (about $8.40 a month): delete it instead.

## What each script does

**gcp.sh create**: enables the Compute API, reserves a static IPv4 (`murmur-edge-ip`), opens TCP
80 and 443 to the VM's tag (`murmur-edge-web`), creates the VM (`murmur-edge`, Debian 12, shielded
boot) with `vm_startup.sh` as its startup script (Docker, curl, daily security updates, rotated
logs, swap on a 1 GB machine), then over ssh: the network test's variables, Caddy for HTTPS, and the
server. HTTPS is for `<address-with-dashes>.sslip.io` unless `--domain` names your own.

**fly.sh create**: the app (`murmur-edge-<random>`), the secret `LIVE_BENCH_KEY`, a shared IPv4
and an IPv6, and one always-on machine (shared-cpu-1x, 1 GB, never stopped for idling), built on
Fly's builders. HTTPS is Fly's, at `<app>.fly.dev`.

**deploy** ships the commit `--ref` names (HEAD by default; uncommitted files are never shipped):
`git archive` of `server/main.ts`, `server/Dockerfile` and the handlers it imports, nothing else.
The working folder never leaves the Mac (it holds Apple keys and env files). The new version starts
beside the old one and takes over once its `/healthz` answers; the old one drains for up to 30 s.
The script prints the version to go back to: `deploy --ref <that version>` (on Google Cloud the
old image is still on the VM, so it starts without a build).

**env `<file>`** gives the server its variables (the list is in `server/README.md`): from a file
outside the repository (or in the git-ignored `scripts/out/`), `NAME=VALUE` lines, no `PORT`. The
script prints the names, never the values. Keep `LIVE_BENCH_KEY` in it, or the host stops
answering the network test. On Google Cloud the file becomes `/etc/murmur/server.env` (mode 600);
on Fly, secrets.

**status** shows the machine, the address and `/healthz`. **delete** removes everything `create`
made (asks you to type the name), takes the host out of the network test's list, and points to the
billing page to check.

`--dry-run` on any command prints every `gcloud` or `fly` command instead of running it, and works
with no account or tools installed. `MURMUR_KEEP_STAGE=<folder>` leaves a copy of exactly what
would be shipped there, to look at.

## Notes

- **sslip.io and certificates.** `sslip.io` is not on the Public Suffix List (checked on
  2026-11-13 against the list of 2026-11-12), so Let's Encrypt counts its certificates for every
  user of the service together; the service says Let's Encrypt raised its limit to 250,000 a week.
  If Caddy can't get a certificate, or sslip.io doesn't resolve from a Russian network, use a name
  of your own: add an A record (for example `edge-test.simplymurmur.com` → the VM's address) and
  create with `--domain edge-test.simplymurmur.com`. Production will use `api.simplymurmur.com`
  that way anyway.
- **Pinned versions.** Caddy `caddy:2.11.6` (in `vm_remote.sh`), Deno `denoland/deno:2.9.7` (in
  `server/Dockerfile`), Debian 12 from Google's `debian-cloud` images.
- **State.** What was created is recorded in `scripts/out/deploy/` (git-ignored), so later
  commands find the VM or app; `delete` removes it.
- **Not run yet.** Everything that needs an account: the real `create`, `deploy`, `env`, `status`
  and `delete` on both platforms, Caddy getting a certificate, the VM's startup script on a real
  VM. Checked on the Mac: every command's dry run in both regions, the generated `fly.toml`
  (parsed as TOML), the staged copy (from an empty Deno cache, started cached-only, it answered the
  network test), and the scripts' helpers.
