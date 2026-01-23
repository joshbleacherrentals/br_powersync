# br_powersync

## Quick start

Run the **Coolify-compatible** compose by default:

```bash
./scripts/start.sh
```

Pass any normal `docker compose up` flags/args (for example, detach):

```bash
./scripts/start.sh -d
```

If you want the **raw/local** multi-file compose instead, pass `--raw`:

```bash
./scripts/start.sh --raw
```

## Why `docker-compose.coolify.yml` exists

Coolify expects a single “flattened” `docker-compose.yml`-style file and does not reliably support advanced compose features we use for local development, such as:

- `include:` (merging other compose YAML files)
- `extends:` (service inheritance)

So we generate a single-file compose output at `docker-compose.coolify.yml`.

## Regenerating the Coolify compose

Source of truth is:

- `docker-compose.yml`
- `services/*.yaml`

Generate the flattened file locally with:

```bash
./scripts/generate-coolify-compose.sh
```

That script runs the Ruby generator:

- `scripts/generate-coolify-compose.rb`

## GitHub automation

On every push, GitHub Actions regenerates `docker-compose.coolify.yml` so it stays in sync:

- `.github/workflows/generate-coolify-compose.yml`
