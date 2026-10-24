#!/usr/bin/env bash
# Optional durable copy; missing onboarding must never hide the build verdict.
set -u
if [[ -z ${AWS_ACCESS_KEY_ID:-} || -z ${MCL_S3_ARTIFACTS_ENDPOINT:-} ]]; then
	echo 'S3 artifact store is not configured; the workflow retains its log copy.'
	exit 0
fi
nix shell --inputs-from . nixpkgs#awscli2 -c \
	aws --endpoint-url "$MCL_S3_ARTIFACTS_ENDPOINT" \
	--region "${MCL_S3_ARTIFACTS_REGION:-garage}" \
	s3 cp --recursive test-logs/ \
	"s3://${MCL_S3_ARTIFACTS_BUCKET:-ci-artifacts}/${S3_OBJECT_PREFIX:?}/" ||
	echo '::warning title=S3 artifact mirror::upload failed (non-blocking)'
