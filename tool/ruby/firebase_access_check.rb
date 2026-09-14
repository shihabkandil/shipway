# frozen_string_literal: true

# Asks Firebase App Distribution whether a service account can reach an app,
# without uploading anything. `shipway release` runs it before building, from
# the platform directory's bundle, which already holds these gems through the
# App Distribution plugin.
#
#   bundle exec ruby firebase_access_check.rb <service-account.json> <app id>
#
# Prints one JSON object and exits 0 whatever the answer: the answer is the
# output. A non-zero exit means this script itself could not run.

require "json"

def answer(fields)
  puts JSON.generate(fields)
  exit 0
end

path, app_id = ARGV
if path.nil? || app_id.nil?
  answer(ok: false, stage: "usage", message: "expected <service-account.json> <app id>")
end

begin
  require "googleauth"
  require "google/apis/firebaseappdistribution_v1"
rescue LoadError => e
  answer(ok: false, stage: "gems", message: e.message)
end

begin
  credentials = Google::Auth::ServiceAccountCredentials.make_creds(
    json_key_io: File.open(path),
    scope: "https://www.googleapis.com/auth/cloud-platform"
  )
  credentials.fetch_access_token!
rescue StandardError => e
  answer(ok: false, stage: "auth", message: e.message)
end

client = Google::Apis::FirebaseappdistributionV1::FirebaseAppDistributionService.new
client.authorization = credentials

# The resource name the plugin itself builds, and the same read-only call its
# get_latest_release action makes.
project_number = app_id.split(":")[1]
begin
  client.list_project_app_releases("projects/#{project_number}/apps/#{app_id}", page_size: 1)
  answer(ok: true)
rescue Google::Apis::Error => e
  answer(ok: false, stage: "api", status: e.status_code, message: e.message)
end
