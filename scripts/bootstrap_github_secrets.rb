#!/usr/bin/env ruby

# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "open3"
require "openssl"
require "optparse"
require "time"
require "uri"

APPLE_API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_IOS_TEAM_ID = "XUC2935G7F"

STATIC_SECRET_NAMES = %w[
  ANDROID_KEYSTORE_BASE64
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS
  ANDROID_KEY_PASSWORD
  APP_STORE_CONNECT_API_KEY_BASE64
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_KEY_ID
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
  IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
].freeze

REQUIRED_ENV_FILE_KEYS = STATIC_SECRET_NAMES.freeze

def fail_with(message)
  warn "Error: #{message}"
  exit 1
end

def run_command(*command, chdir: nil, stdin_data: nil)
  options = {}
  options[:chdir] = chdir if chdir
  options[:stdin_data] = stdin_data if stdin_data
  stdout, stderr, status = Open3.capture3(*command, options)
  return stdout if status.success?

  details = stderr.strip.empty? ? stdout.strip : stderr.strip
  fail_with("#{command.join(' ')} failed#{details.empty? ? '' : ":\n#{details}"}")
end

def base64url_encode(value)
  Base64.strict_encode64(value).tr("+/", "-_").delete("=")
end

def parse_env_file(path)
  values = {}
  current_key = nil
  buffer = []

  File.readlines(path, chomp: true).each do |line|
    if (match = line.match(/\A([A-Z0-9_]+)=(.*)\z/))
      values[current_key] = buffer.join("\n").sub(/\A\n/, "").rstrip if current_key
      current_key = match[1]
      buffer = [match[2]]
    elsif current_key
      buffer << line
    elsif !line.strip.empty?
      fail_with("Unexpected line before first KEY=VALUE entry in #{path}: #{line}")
    end
  end

  values[current_key] = buffer.join("\n").sub(/\A\n/, "").rstrip if current_key
  values
end

def generate_app_store_token(key_id:, issuer_id:, key_content_base64:)
  private_key = OpenSSL::PKey.read(Base64.decode64(key_content_base64))
  now = Time.now.to_i
  header = base64url_encode(JSON.generate({ alg: "ES256", kid: key_id, typ: "JWT" }))
  payload = base64url_encode(JSON.generate({ iss: issuer_id, aud: "appstoreconnect-v1", exp: now + 1200 }))
  signing_input = "#{header}.#{payload}"
  der_signature = private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
  asn1 = OpenSSL::ASN1.decode(der_signature)
  raw_signature = asn1.value.map do |integer|
    hex = integer.value.to_i.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    [hex].pack("H*").rjust(32, "\x00")
  end.join

  "#{signing_input}.#{base64url_encode(raw_signature)}"
end

def apple_request(method:, path:, token:, body: nil)
  uri = URI("#{APPLE_API_BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = case method
            when :get then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            else
              fail_with("Unsupported Apple API method: #{method}")
            end

  request["Authorization"] = "Bearer #{token}"
  request["Accept"] = "application/json"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body

  response = http.request(request)
  return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

  fail_with("Apple API #{method.to_s.upcase} #{uri} failed (#{response.code}): #{response.body}")
end

def fetch_bundle_id_resource_id(bundle_id:, token:)
  query = URI.encode_www_form(
    "filter[identifier]" => bundle_id,
    "filter[platform]" => "IOS",
    "limit" => "20"
  )
  response = apple_request(method: :get, path: "/bundleIds?#{query}", token: token)
  match = response.fetch("data", []).find do |row|
    row.dig("attributes", "identifier") == bundle_id
  end
  fail_with("No Apple bundle ID resource found for #{bundle_id}. Create the App ID first.") unless match

  match.fetch("id")
end

def fetch_app_store_apple_id(bundle_id:, token:)
  query = URI.encode_www_form(
    "filter[bundleId]" => bundle_id,
    "limit" => "20"
  )
  response = apple_request(method: :get, path: "/apps?#{query}", token: token)
  match = response.fetch("data", []).find do |row|
    row.dig("attributes", "bundleId") == bundle_id
  end
  fail_with("No App Store Connect app record found for #{bundle_id}. Create the app record first.") unless match

  match.fetch("id")
end

def fetch_certificate_resource(certificate_id:, token:)
  response = apple_request(method: :get, path: "/certificates/#{certificate_id}", token: token)
  response.fetch("data")
rescue StandardError => error
  fail_with("Unable to find Apple certificate #{certificate_id}: #{error.message}")
end

def create_profile(bundle_id_resource_id:, certificate_id:, profile_name:, token:)
  payload = {
    data: {
      type: "profiles",
      attributes: {
        name: profile_name,
        profileType: "IOS_APP_STORE"
      },
      relationships: {
        bundleId: {
          data: {
            type: "bundleIds",
            id: bundle_id_resource_id
          }
        },
        certificates: {
          data: [
            {
              type: "certificates",
              id: certificate_id
            }
          ]
        }
      }
    }
  }

  response = apple_request(method: :post, path: "/profiles", token: token, body: payload)
  profile = response.fetch("data")
  profile_content = profile.dig("attributes", "profileContent")
  return [profile, profile_content.delete("\n")] if profile_content

  profile_id = profile.fetch("id")
  fetched = apple_request(method: :get, path: "/profiles/#{profile_id}", token: token).fetch("data")
  fetched_content = fetched.dig("attributes", "profileContent")
  fail_with("Apple created profile #{profile_id} but did not return profileContent.") unless fetched_content

  [fetched, fetched_content.delete("\n")]
end

def set_github_secret(name:, value:, repo:)
  run_command("gh", "secret", "set", name, "--repo", repo, stdin_data: value)
end

def set_github_variable(name:, value:, repo:)
  run_command("gh", "variable", "set", name, "--repo", repo, "--body", value)
end

options = {
  shared_secrets_file: nil,
  profile_name: nil
}

parser = OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage:
      ./scripts/bootstrap_github_secrets.rb \\
        --bundle-id com.company.app \\
        --certificate-id 2P8565M49U \\
        [--shared-secrets-file ../shared-secrets/android-gha-secrets.env] \\
        [--profile-name "com.company.app App Store CI"]

    Creates an App Store provisioning profile for an existing Apple App ID,
    base64-encodes it, and stores the required GitHub Actions secrets on the
    current repository.
  USAGE

  opts.on("--bundle-id BUNDLE_ID", "Existing Apple bundle identifier / App ID") do |value|
    options[:bundle_id] = value
  end

  opts.on("--certificate-id CERTIFICATE_ID", "Apple certificate resource ID to attach to the profile") do |value|
    options[:certificate_id] = value
  end

  opts.on("--shared-secrets-file PATH", "Path to shared-secrets/android-gha-secrets.env") do |value|
    options[:shared_secrets_file] = value
  end

  opts.on("--profile-name NAME", "Optional provisioning profile display name") do |value|
    options[:profile_name] = value
  end

  opts.on("--help", "-h", "Show this help") do
    puts opts
    exit 0
  end
end

parser.parse!

fail_with("--bundle-id is required") if options[:bundle_id].to_s.strip.empty?
fail_with("--certificate-id is required") if options[:certificate_id].to_s.strip.empty?

repo_root = run_command("git", "rev-parse", "--show-toplevel").strip

shared_secrets_file = options[:shared_secrets_file]
if shared_secrets_file.nil? || shared_secrets_file.empty?
  candidates = [
    File.expand_path("../shared-secrets/android-gha-secrets.env", repo_root),
    File.expand_path("shared-secrets/android-gha-secrets.env", repo_root)
  ]
  shared_secrets_file = candidates.find { |candidate| File.exist?(candidate) }
end

fail_with("Unable to find shared-secrets/android-gha-secrets.env. Pass --shared-secrets-file.") unless shared_secrets_file
fail_with("Shared secrets file not found: #{shared_secrets_file}") unless File.exist?(shared_secrets_file)

shared_values = parse_env_file(shared_secrets_file)
missing = REQUIRED_ENV_FILE_KEYS.reject { |key| shared_values[key] && !shared_values[key].empty? }
fail_with("Missing required keys in #{shared_secrets_file}: #{missing.join(', ')}") unless missing.empty?

run_command("gh", "auth", "status")
current_repo = run_command("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner", chdir: repo_root).strip

token = generate_app_store_token(
  key_id: shared_values.fetch("APP_STORE_CONNECT_KEY_ID"),
  issuer_id: shared_values.fetch("APP_STORE_CONNECT_ISSUER_ID"),
  key_content_base64: shared_values.fetch("APP_STORE_CONNECT_API_KEY_BASE64")
)

bundle_id_resource_id = fetch_bundle_id_resource_id(bundle_id: options[:bundle_id], token: token)
certificate = fetch_certificate_resource(certificate_id: options[:certificate_id], token: token)
certificate_name = certificate.dig("attributes", "name") || options[:certificate_id]
app_store_apple_id = fetch_app_store_apple_id(bundle_id: options[:bundle_id], token: token)
profile_name = options[:profile_name] || "#{options[:bundle_id]} App Store #{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
profile, profile_content_base64 = create_profile(
  bundle_id_resource_id: bundle_id_resource_id,
  certificate_id: options[:certificate_id],
  profile_name: profile_name,
  token: token
)

secrets_to_set = STATIC_SECRET_NAMES.to_h do |key|
  [key, shared_values.fetch(key)]
end
secrets_to_set["IOS_PROVISIONING_PROFILE_BASE64"] = profile_content_base64

variables_to_set = {
  "APP_STORE_APPLE_ID" => app_store_apple_id,
  "BUNDLE_ID" => options[:bundle_id],
  "IOS_TEAM_ID" => DEFAULT_IOS_TEAM_ID
}

secrets_to_set.each do |name, value|
  set_github_secret(name: name, value: value, repo: current_repo)
  puts "Set GitHub secret #{name} on #{current_repo}"
end

variables_to_set.each do |name, value|
  set_github_variable(name: name, value: value, repo: current_repo)
  puts "Set GitHub variable #{name}=#{value} on #{current_repo}"
end

puts "Created provisioning profile #{profile.dig('attributes', 'name')} (#{profile.dig('attributes', 'uuid')})"
puts "Bundle ID: #{options[:bundle_id]}"
puts "App Store Apple ID: #{app_store_apple_id}"
puts "iOS Team ID: #{DEFAULT_IOS_TEAM_ID}"
puts "Certificate: #{certificate_name} (#{options[:certificate_id]})"
