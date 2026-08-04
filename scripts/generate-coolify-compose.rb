#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)

SOURCE_PATH = File.join(ROOT, "docker-compose.yml")
OUTPUT_PATH = File.join(ROOT, "docker-compose.coolify.yml")

# Deep merge hashes. Arrays are replaced (not concatenated) because compose arrays
# like `volumes:` should be overridden by the more specific file.
#
# For our repo:
# - docker-compose.yml is the root entrypoint
# - include files provide additional services/volumes
# - extends files provide base service definitions

def deep_merge(base, override)
  return override if base.nil?
  return base if override.nil?

  if base.is_a?(Hash) && override.is_a?(Hash)
    merged = base.dup
    override.each do |k, v|
      merged[k] = deep_merge(base[k], v)
    end
    merged
  else
    # Arrays + scalars: override completely
    override
  end
end

def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: true) || {}
end

root = load_yaml(SOURCE_PATH)

# Path (inside the container) to the mounted PowerSync config file.
# PowerSync resolves sync_rules.yaml relative to this file's directory.
POWERSYNC_CONFIG_TARGET = "/config/powersync.yaml"

# Resolve `include:` by merging included docs first, then root overrides.
includes = root.delete("include") || []
merged_from_includes = {}

includes.each do |entry|
  next unless entry.is_a?(Hash) && entry["path"]

  include_path = File.expand_path(entry["path"], ROOT)
  included = load_yaml(include_path)
  merged_from_includes = deep_merge(merged_from_includes, included)
end

compose = deep_merge(merged_from_includes, root)

services = compose["services"] || {}

# Resolve `extends:` inside services.
services.each do |_name, service|
  next unless service.is_a?(Hash) && service["extends"].is_a?(Hash)

  extends = service.delete("extends")
  file = extends["file"]
  service_name = extends["service"]

  next unless file && service_name

  extends_path = File.expand_path(file, ROOT)
  extends_doc = load_yaml(extends_path)
  base_service = extends_doc.dig("services", service_name)

  unless base_service
    warn("Could not resolve extends service '#{service_name}' in #{file}")
    next
  end

  # Base service comes first, then service overrides.
  merged_service = deep_merge(base_service, service)

  service.clear
  merged_service.each { |k, v| service[k] = v }
end

# Remove local-only external Supabase docker network references.
# (Production PowerSync connects to Supabase over the internet via PS_DATA_SOURCE_URI.)

def remove_network_reference!(compose, network_name)
  networks = compose["networks"]
  networks&.delete(network_name)

  (compose["services"] || {}).each_value do |svc|
    next unless svc.is_a?(Hash)

    svc_networks = svc["networks"]
    case svc_networks
    when Array
      svc_networks.delete(network_name)
      svc.delete("networks") if svc_networks.empty?
    when Hash
      svc_networks.delete(network_name)
      svc.delete("networks") if svc_networks.empty?
    end
  end
end

remove_network_reference!(compose, "supabase_network_bleacher_rentals")

# Also remove any other supabase external networks that might be present.
(compose["networks"] || {}).keys.grep(/^supabase_network_/).each do |name|
  remove_network_reference!(compose, name)
end

# Normalize the PowerSync service env to be Coolify-friendly.
# The upstream service definition hardcodes PS_MONGO_URI, but we want it to come from Coolify env vars.
powersync_service = compose.dig("services", "powersync")
powersync_env = compose.dig("services", "powersync", "environment")

if powersync_env.is_a?(Hash)
  if powersync_env["PS_MONGO_URI"] && !powersync_env["PS_MONGO_URI"].to_s.include?("${")
    powersync_env["PS_MONGO_URI"] = "${PS_MONGO_URI}"
  end

  # Deliver config by mounting the repo files (see volumes below) rather than
  # base64-inlining it. Base64-inlining bloated this compose file to ~96 KB, which
  # tipped Coolify's file-copy step past the OS single-argument limit (E2BIG,
  # "Argument list too long"). Mounting keeps this file small and lets sync rules grow.
  powersync_env.delete("POWERSYNC_CONFIG_B64")
  powersync_env["POWERSYNC_CONFIG_PATH"] = POWERSYNC_CONFIG_TARGET
end

# Mount the PowerSync config files from the repo as individual files.
#
# Each file uses Coolify's `is_directory: false` annotation. Without it, Coolify
# has historically created a *directory* at the target path (coollabsio/coolify
# #3375, #8107), which breaks single-file config mounts.
#
# Requires "Preserve Repository During Deployment" enabled on the Coolify resource
# so the repo files exist on the host at mount time.
#
# `is_directory` is Coolify-only; plain Docker ignores it, so the local
# docker-compose.yml (which mounts ./config wholesale) is unaffected.
if powersync_service.is_a?(Hash)
  powersync_service["volumes"] = [
    {
      "type" => "bind",
      "source" => "./config/powersync.yaml",
      "target" => POWERSYNC_CONFIG_TARGET,
      "is_directory" => false,
    },
    {
      "type" => "bind",
      "source" => "./config/sync_rules.yaml",
      "target" => "/config/sync_rules.yaml",
      "is_directory" => false,
    },
  ]
end

# Coolify runs multiple compose resources on the same host.
# Publishing host ports (e.g. 8080:8080, 27017:27017) will collide across dev/staging/prod.
# Instead, we let Coolify's proxy route to the container port internally.
# Traefik reads the port directly from the domain field (e.g. https://ps-prod.example.com:8080).
["mongo", "powersync"].each do |name|
  svc = compose.dig("services", name)
  svc&.delete("ports")
end

# Supabase hosted Postgres direct connection endpoints are IPv6-only.
# Enable IPv6 on the default Docker network so containers can reach db.<ref>.supabase.co.
#
# NOTE:
# We intentionally do NOT hardcode an IPv6 subnet here.
# Docker will auto-allocate a non-overlapping /64 for each network, which avoids
# "Pool overlaps" errors when Coolify creates/recreates networks.
compose["networks"] = {} unless compose["networks"].is_a?(Hash)

default_network = compose["networks"]["default"]
default_network = {} unless default_network.is_a?(Hash)

default_network["enable_ipv6"] = true
# If a source compose defined custom IPAM, drop it for Coolify to prevent overlaps.
default_network.delete("ipam")

compose["networks"]["default"] = default_network

header = <<~HEADER
  # -----------------------------------------------------------------------------
  # THIS FILE IS AUTO-GENERATED.
  #
  # Source of truth:
  #   - docker-compose.yml
  #   - services/*.yaml
  #
  # Why this exists:
  #   Coolify's docker-compose ingestion does not reliably support advanced/multi-
  #   file compose features (like `include:` and `extends:`) that we use locally.
  #   This generated file flattens the compose into a single document that Coolify
  #   can deploy.
  #
  # IMPORTANT:
  #   - Do not edit this file by hand.
  #   - Edit docker-compose.yml or services/*.yaml instead.
  #   - Then run: ./scripts/generate-coolify-compose.sh
  #
  # CI:
  #   .github/workflows/generate-coolify-compose.yml regenerates this file on push.
  #
  # Coolify routing:
  #   We intentionally DO NOT publish host ports here. Coolify's proxy should route
  #   ps-dev/ps-staging/ps-prod subdomains to the internal container port.
  #
  # Networking:
  #   Supabase hosted Postgres direct DB endpoints are IPv6-only.
  #   This compose enables IPv6 on the default Docker network.
  #   We do not hardcode an IPv6 subnet; Docker auto-allocates one per network.
  #
  # Config delivery:
  #   PowerSync config is mounted from the repo as individual files (see the
  #   powersync `volumes:` block) using Coolify's `is_directory: false` annotation.
  #   The Coolify resource must have "Preserve Repository During Deployment" enabled
  #   so ./config/*.yaml exist on the host at mount time.
  #   (We previously base64-inlined the config into POWERSYNC_CONFIG_B64, but that
  #   bloated this file until Coolify's file-copy step hit the OS argument-length
  #   limit — "Argument list too long".)
  # -----------------------------------------------------------------------------

HEADER

yaml = YAML.dump(compose)
# Some Compose parsers (including certain platform ingestors) are picky about the
# explicit document start marker. Remove it for maximum compatibility.
yaml = yaml.sub(/\A---\s*\n/, "")

File.write(OUTPUT_PATH, header + yaml)

puts("Wrote #{OUTPUT_PATH}")
