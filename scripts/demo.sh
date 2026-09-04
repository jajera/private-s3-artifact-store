#!/usr/bin/env bash
# CLI lab orchestrator: private S3 artifact store (gateway VPCE + Syd to Akl CRR).
# Echoes AWS commands before running them.
#
# Usage: ./scripts/demo.sh <command>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ROOT}/.lab-state.json"
TAG_KEY="Project"
TAG_VALUE="private-s3-artifact-store"
NAME_PREFIX="${NAME_PREFIX:-ps3a}"
PRIMARY_REGION="ap-southeast-2"
REPLICA_REGION="ap-southeast-6"
DEMO_PREFIX="demo/"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/demo.sh <command>

Commands:
  up-shared              Create primary + replica buckets and CRR (demo/)
  up-consumer syd|akl    Demo VPC + gateway VPCE + SSM endpoints + probe EC2
  allowlist              Lock bucket policies to VPCE IDs in .lab-state.json
  publish [file]         Upload under demo/ and wait for replica
  prove syd|akl          SSM Run Command curl of the regional object URL
  status                 Show .lab-state.json summary (read-only)
  down                   Tear down lab resources (confirmation required)

Required environment:
  AWS_PROFILE   Named profile (e.g. sandbox)

Optional:
  LAB_SUFFIX  NAME_PREFIX
EOF
}

run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

require_env() {
  [[ -n "${AWS_PROFILE:-}" ]] || die "AWS_PROFILE is unset"
  command -v aws >/dev/null || die "aws CLI not found"
  command -v jq >/dev/null || die "jq not found"
}

account_id() {
  aws sts get-caller-identity --query Account --output text
}

caller_arn() {
  aws sts get-caller-identity --query Arn --output text
}

state_init() {
  if [[ ! -f "$STATE_FILE" ]]; then
    local suffix="${LAB_SUFFIX:-$(date -u +%Y%m%d%H%M%S)}"
    local acct
    acct="$(account_id)"
    cat >"$STATE_FILE" <<EOF
{
  "suffix": "$suffix",
  "account_id": "$acct",
  "name_prefix": "$NAME_PREFIX",
  "primary_region": "$PRIMARY_REGION",
  "replica_region": "$REPLICA_REGION",
  "demo_prefix": "$DEMO_PREFIX",
  "consumers": {}
}
EOF
  fi
}

state_get() {
  jq -r "$1" "$STATE_FILE"
}

state_set() {
  # usage: state_set '.path' '"value"'  OR state_set '.path' 'json'
  local filter="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --argjson v "$value" "$filter = \$v" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

# For string values
state_set_str() {
  local filter="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$value" "$filter = \$v" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

cmd_status() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "no state file; run up-shared first"
  jq . "$STATE_FILE"
}

ensure_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    printf 'bucket exists: %s\n' "$bucket" >&2
    return 0
  fi
  if [[ "$region" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$bucket" --region "$region"
  else
    run aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region"
  fi
  run aws s3api put-bucket-tagging --bucket "$bucket" --region "$region" \
    --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"
  run aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  run aws s3api put-bucket-ownership-controls --bucket "$bucket" --region "$region" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  run aws s3api put-bucket-versioning --bucket "$bucket" --region "$region" \
    --versioning-configuration Status=Enabled
  run aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

cmd_up_shared() {
  require_env
  export AWS_DEFAULT_REGION="$PRIMARY_REGION"
  state_init
  local acct suffix primary replica role
  acct="$(state_get .account_id)"
  suffix="$(state_get .suffix)"
  primary="${NAME_PREFIX}-artifacts-${acct}-syd"
  replica="${NAME_PREFIX}-artifacts-${acct}-akl"
  role="${NAME_PREFIX}-crr-${suffix}"

  ensure_bucket "$primary" "$PRIMARY_REGION"
  ensure_bucket "$replica" "$REPLICA_REGION"
  # Persist early so `down` can clean up if a later step fails.
  state_set_str '.primary_bucket' "$primary"
  state_set_str '.replica_bucket' "$replica"

  # CRR role
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  local crr_policy
  crr_policy="$(jq -n --arg primary "$primary" --arg replica "$replica" '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["s3:GetReplicationConfiguration", "s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($primary)"]
      },
      {
        Effect: "Allow",
        Action: [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ],
        Resource: ["arn:aws:s3:::\($primary)/*"]
      },
      {
        Effect: "Allow",
        Action: [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:ObjectOwnerOverrideToBucketOwner"
        ],
        Resource: ["arn:aws:s3:::\($replica)/*"]
      }
    ]
  }')"
  run aws iam put-role-policy --role-name "$role" --policy-name crr \
    --policy-document "$crr_policy"
  local role_arn
  role_arn="$(aws iam get-role --role-name "$role" --query Role.Arn --output text)"
  state_set_str '.crr_role_arn' "$role_arn"

  # Replication config
  run aws s3api put-bucket-replication --bucket "$primary" --region "$PRIMARY_REGION" \
    --replication-configuration "$(jq -n \
      --arg role "$role_arn" \
      --arg replica "$replica" \
      --arg prefix "$DEMO_PREFIX" '{
        Role: $role,
        Rules: [{
          ID: "demo-to-akl",
          Status: "Enabled",
          Priority: 1,
          Filter: {Prefix: $prefix},
          DeleteMarkerReplication: {Status: "Enabled"},
          Destination: {Bucket: "arn:aws:s3:::\($replica)", StorageClass: "STANDARD"}
        }]
      }')"

  # Bootstrap policies: admin + CRR can access; VPCE lock applied later
  local admin_arn bypass=""
  admin_arn="$(caller_arn)"
  # Prefer the IAM role ARN (SSO permission sets live under aws-reserved/…).
  # Never put an STS session ARN in a bucket policy Principal.
  if [[ "$admin_arn" == *assumed-role* ]]; then
    local role_name
    role_name="${admin_arn#*assumed-role/}"
    role_name="${role_name%%/*}"
    if [[ -n "$role_name" ]]; then
      bypass="$(aws iam get-role --role-name "$role_name" --query Role.Arn --output text 2>/dev/null || true)"
    fi
  elif [[ "$admin_arn" == arn:aws:iam::* ]]; then
    bypass="$admin_arn"
  fi
  [[ -n "$bypass" && "$bypass" == arn:aws:iam::* ]] || \
    die "could not resolve IAM role ARN for bucket policy bypass (caller=$admin_arn)"

  write_openish_policy() {
    local bucket="$1" region="$2" extra_principals="$3"
    local principals_json doc i
    principals_json="$(jq -n --arg crr "$role_arn" --arg extras "$extra_principals" '
      ([$crr] + ($extras | split(",") | map(select(length > 0)))) | unique
    ')"
    doc="$(jq -n --arg bucket "$bucket" --argjson principals "$principals_json" '
      {
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "AllowBypassPrincipals",
            Effect: "Allow",
            Principal: {
              AWS: (if ($principals | length) == 1 then $principals[0] else $principals end)
            },
            Action: "s3:*",
            Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"]
          },
          {
            Sid: "AllowSSLRequestsOnly",
            Effect: "Deny",
            Principal: "*",
            Action: "s3:*",
            Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"],
            Condition: {Bool: {"aws:SecureTransport": "false"}}
          }
        ]
      }
    ')"
    # Newly created IAM roles are often rejected as Invalid principal for a few seconds.
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf '+ aws s3api put-bucket-policy --bucket %s --region %s ...\n' "$bucket" "$region" >&2
      if aws s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "$doc"; then
        return 0
      fi
      printf 'warn: put-bucket-policy %s failed (try %s/10); waiting for IAM propagation\n' \
        "$bucket" "$i" >&2
      sleep 5
    done
    die "put-bucket-policy failed for $bucket after retries"
  }

  write_openish_policy "$primary" "$PRIMARY_REGION" "$bypass"
  write_openish_policy "$replica" "$REPLICA_REGION" "$bypass"
  state_set_str '.bypass_principal_arn' "$bypass"
  printf 'up-shared complete: %s → %s\n' "$primary" "$replica" >&2
}

cmd_up_consumer() {
  require_env
  local which="${1:-}"
  [[ "$which" == "syd" || "$which" == "akl" ]] || die "up-consumer requires syd|akl"
  [[ -f "$STATE_FILE" ]] || die "run up-shared first"

  local existing
  existing="$(jq -r --arg w "$which" '.consumers[$w].instance_id // empty' "$STATE_FILE")"
  [[ -z "$existing" ]] || die "consumer $which already exists ($existing); run down first"

  local region bucket vpc_cidr subnet_cidr
  if [[ "$which" == "syd" ]]; then
    region="$PRIMARY_REGION"
    bucket="$(state_get .primary_bucket)"
    vpc_cidr="10.80.0.0/16"
    subnet_cidr="10.80.1.0/24"
  else
    region="$REPLICA_REGION"
    bucket="$(state_get .replica_bucket)"
    vpc_cidr="10.81.0.0/16"
    subnet_cidr="10.81.1.0/24"
  fi
  [[ -n "$bucket" && "$bucket" != "null" ]] || die "missing bucket in state; run up-shared first"
  # Pin both: a sticky AWS_REGION from the shell overrides AWS_DEFAULT_REGION.
  export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
  local suffix
  suffix="$(state_get .suffix)"
  local name="${NAME_PREFIX}-${which}-${suffix}"

  # Dedicated private VPC for this consumer (no IGW/NAT; S3 gateway + SSM VPCEs).
  local az vpc_id subnet_id rtb_id
  az="$(aws ec2 describe-availability-zones --region "$region" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"
  vpc_id="$(run aws ec2 create-vpc --region "$region" --cidr-block "$vpc_cidr" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-vpc}]" \
    --query 'Vpc.VpcId' --output text)"
  run aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc_id" --enable-dns-support
  run aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc_id" --enable-dns-hostnames
  subnet_id="$(run aws ec2 create-subnet --region "$region" --vpc-id "$vpc_id" --cidr-block "$subnet_cidr" \
    --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-subnet}]" \
    --query 'Subnet.SubnetId' --output text)"
  rtb_id="$(run aws ec2 create-route-table --region "$region" --vpc-id "$vpc_id" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-rtb}]" \
    --query 'RouteTable.RouteTableId' --output text)"
  run aws ec2 associate-route-table --region "$region" --route-table-id "$rtb_id" --subnet-id "$subnet_id" >/dev/null

  # S3 gateway on the lab route table
  local vpce_id
  vpce_id="$(run aws ec2 create-vpc-endpoint --region "$region" \
    --vpc-id "$vpc_id" \
    --vpc-endpoint-type Gateway \
    --service-name "com.amazonaws.${region}.s3" \
    --route-table-ids "$rtb_id" \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-s3}]" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)"

  # IAM
  local role="${name}-ec2"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    run aws iam create-role --role-name "$role" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=$TAG_KEY,Value=$TAG_VALUE"
  fi
  run aws iam attach-role-policy --role-name "$role" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  run aws iam put-role-policy --role-name "$role" --policy-name artifact-read \
    --policy-document "$(jq -n --arg b "$bucket" '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"]
      }]
    }')"
  if ! aws iam get-instance-profile --instance-profile-name "$role" >/dev/null 2>&1; then
    run aws iam create-instance-profile --instance-profile-name "$role"
    run aws iam add-role-to-instance-profile --instance-profile-name "$role" --role-name "$role"
    sleep 8
  fi

  # Security groups
  local sg_ec2 sg_ssm
  sg_ec2="$(run aws ec2 create-security-group --region "$region" --group-name "${name}-ec2" --description "probe" \
    --vpc-id "$vpc_id" --query GroupId --output text)"
  run aws ec2 create-tags --region "$region" --resources "$sg_ec2" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=Name,Value=${name}-ec2"
  run aws ec2 authorize-security-group-egress --region "$region" --group-id "$sg_ec2" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" || true

  sg_ssm="$(run aws ec2 create-security-group --region "$region" --group-name "${name}-ssm" --description "ssm vpce" \
    --vpc-id "$vpc_id" --query GroupId --output text)"
  run aws ec2 create-tags --region "$region" --resources "$sg_ssm" --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=Name,Value=${name}-ssm"
  run aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg_ssm" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$vpc_cidr}]"
  run aws ec2 authorize-security-group-egress --region "$region" --group-id "$sg_ssm" \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" || true

  # SSM interface endpoints (private subnet has no NAT).
  # Some Regions (notably ap-southeast-6) may lack ec2messages; skip if missing.
  local ssm_vpces=()
  for svc in ssm ssmmessages ec2messages; do
    local id
    if id="$(aws ec2 create-vpc-endpoint --region "$region" \
      --vpc-id "$vpc_id" \
      --vpc-endpoint-type Interface \
      --service-name "com.amazonaws.${region}.${svc}" \
      --subnet-ids "$subnet_id" \
      --security-group-ids "$sg_ssm" \
      --private-dns-enabled \
      --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=${name}-${svc}}]" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)"; then
      printf '+ created interface endpoint %s -> %s\n' "$svc" "$id" >&2
      ssm_vpces+=("$id")
    else
      printf 'warn: skipping interface endpoint %s in %s (service unavailable)\n' "$svc" "$region" >&2
    fi
  done
  [[ ${#ssm_vpces[@]} -ge 2 ]] || die "need at least ssm + ssmmessages VPCEs in $region"

  local ami
  ami="$(aws ec2 describe-images --region "$region" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"

  local iid
  iid="$(run aws ec2 run-instances --region "$region" \
    --image-id "$ami" \
    --instance-type t3.micro \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_ec2" \
    --iam-instance-profile "Name=$role" \
    --no-associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=$name}]" \
    --query 'Instances[0].InstanceId' --output text)"

  local vpces_json
  if [[ ${#ssm_vpces[@]} -eq 0 ]]; then
    vpces_json='[]'
  else
    vpces_json="$(jq -n --args '$ARGS.positional' -- "${ssm_vpces[@]}")"
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg which "$which" \
    --arg region "$region" \
    --arg bucket "$bucket" \
    --arg vpc "$vpc_id" \
    --arg subnet "$subnet_id" \
    --arg rtb "$rtb_id" \
    --arg vpce "$vpce_id" \
    --arg iid "$iid" \
    --arg role "$role" \
    --arg sg_ec2 "$sg_ec2" \
    --arg sg_ssm "$sg_ssm" \
    --argjson ssm_vpces "$vpces_json" \
    '.consumers[$which] = {
      region:$region, bucket:$bucket,
      vpc_id:$vpc, subnet_id:$subnet, route_table_id:$rtb, created_vpc:true,
      s3_vpce_id:$vpce, created_s3_vpce:true,
      instance_id:$iid, instance_profile:$role, role_name:$role,
      sg_ec2:$sg_ec2, sg_ssm:$sg_ssm, ssm_vpce_ids:$ssm_vpces
    }' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
  printf 'up-consumer %s complete: vpc=%s instance=%s s3_vpce=%s\n' \
    "$which" "$vpc_id" "$iid" "$vpce_id" >&2
}

cmd_allowlist() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "missing state"
  local primary replica role bypass
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  role="$(state_get .crr_role_arn)"
  bypass="$(state_get .bypass_principal_arn)"

  local syd_vpces akl_vpces
  syd_vpces="$(jq -c '[.consumers[]? | select(.region=="ap-southeast-2") | .s3_vpce_id] | unique' "$STATE_FILE")"
  akl_vpces="$(jq -c '[.consumers[]? | select(.region=="ap-southeast-6") | .s3_vpce_id] | unique' "$STATE_FILE")"

  put_locked_policy() {
    local bucket="$1" region="$2" vpces_json="$3"
    local doc
    doc="$(jq -n \
      --arg bucket "$bucket" \
      --arg role "$role" \
      --arg bypass "$bypass" \
      --argjson vpces "$vpces_json" '
      def res: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"];
      {
        Version: "2012-10-17",
        Statement: (
          [
            {
              Sid: "AllowBypassPrincipals",
              Effect: "Allow",
              Principal: {AWS: [$bypass, $role]},
              Action: "s3:*",
              Resource: res
            },
            {
              Sid: "AllowSSLRequestsOnly",
              Effect: "Deny",
              Principal: "*",
              Action: "s3:*",
              Resource: res,
              Condition: {Bool: {"aws:SecureTransport": "false"}}
            }
          ]
          + (if ($vpces | length) > 0 then [
            {
              Sid: "DenyNonVpce",
              Effect: "Deny",
              Principal: "*",
              Action: "s3:*",
              Resource: res,
              Condition: {
                StringNotEquals: {"aws:SourceVpce": $vpces},
                ArnNotEquals: {"aws:PrincipalArn": [$bypass, $role]}
              }
            },
            {
              Sid: "AllowVpceRead",
              Effect: "Allow",
              Principal: "*",
              Action: ["s3:GetObject", "s3:ListBucket"],
              Resource: res,
              Condition: {StringEquals: {"aws:SourceVpce": $vpces}}
            }
          ] else [] end)
        )
      }
    ')"
    run aws s3api put-bucket-policy --bucket "$bucket" --region "$region" --policy "$doc"
  }

  put_locked_policy "$primary" "$PRIMARY_REGION" "$syd_vpces"
  put_locked_policy "$replica" "$REPLICA_REGION" "$akl_vpces"
  printf 'allowlist applied (syd=%s akl=%s)\n' "$syd_vpces" "$akl_vpces" >&2
}

cmd_publish() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "missing state"
  local primary replica key file
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  file="${1:-}"
  local tmp=""
  if [[ -z "$file" ]]; then
    tmp="$(mktemp)"
    file="$tmp"
    cat >"$file" <<EOF
private-s3-artifact-store demo object
created_utc=$(date -u +%Y%m%dT%H%M%SZ)
primary_bucket=$primary
primary_region=$PRIMARY_REGION
EOF
  fi
  key="${DEMO_PREFIX}see-$(date -u +%Y%m%dT%H%M%SZ).txt"
  run aws s3 cp "$file" "s3://${primary}/${key}" --region "$PRIMARY_REGION" \
    --content-type text/plain
  [[ -n "$tmp" ]] && rm -f "$tmp"
  state_set_str '.demo_key' "$key"

  printf 'waiting for CRR to %s ...\n' "$replica" >&2
  for i in $(seq 1 36); do
    if aws s3api head-object --bucket "$replica" --key "$key" --region "$REPLICA_REGION" >/dev/null 2>&1; then
      printf 'replicated: s3://%s/%s\n' "$replica" "$key" >&2
      return 0
    fi
    sleep 5
  done
  die "CRR timeout for $key"
}

cmd_prove() {
  require_env
  local which="${1:-}"
  [[ "$which" == "syd" || "$which" == "akl" ]] || die "prove requires syd|akl"
  [[ -f "$STATE_FILE" ]] || die "missing state"
  local iid region bucket key url
  iid="$(jq -r --arg w "$which" '.consumers[$w].instance_id // empty' "$STATE_FILE")"
  region="$(jq -r --arg w "$which" '.consumers[$w].region // empty' "$STATE_FILE")"
  bucket="$(jq -r --arg w "$which" '.consumers[$w].bucket // empty' "$STATE_FILE")"
  key="$(state_get .demo_key)"
  [[ -n "$key" && "$key" != null ]] || die "missing demo_key; run publish first"
  [[ -n "$iid" && -n "$region" && -n "$bucket" ]] || die "missing consumer $which; run up-consumer $which first"
  url="https://${bucket}.s3.${region}.amazonaws.com/${key}"
  local cmd_id
  # Single shell script: curl via regional hostname (gateway VPCE), print exit.
  cmd_id="$(run aws ssm send-command \
    --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --region "$region" \
    --parameters "commands=[\"curl -fsSL '$url'; echo; echo EXIT:\$?\"]" \
    --query 'Command.CommandId' --output text)"
  local i status
  for i in $(seq 1 20); do
    sleep 2
    status="$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$iid" \
      --region "$region" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
  done
  run aws ssm get-command-invocation \
    --command-id "$cmd_id" \
    --instance-id "$iid" \
    --region "$region" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json
}

empty_bucket() {
  local bucket="$1" region="$2"
  printf 'emptying %s (%s)\n' "$bucket" "$region" >&2
  local page objs n i del chunk
  page="$(aws s3api list-object-versions --bucket "$bucket" --region "$region" --output json 2>/dev/null || true)"
  [[ -n "$page" ]] || return 0
  objs="$(jq -c '
    [(.Versions // [])[] | {Key, VersionId}]
    + [(.DeleteMarkers // [])[] | {Key, VersionId}]
  ' <<<"$page")"
  n="$(jq 'length' <<<"$objs")"
  [[ "$n" -gt 0 ]] || return 0
  del="$(mktemp)"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    chunk="$(jq -c --argjson i "$i" '{Objects: .[$i:$i+1000], Quiet: true}' <<<"$objs")"
    printf '%s\n' "$chunk" >"$del"
    run aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "file://${del}" || true
    i=$((i + 1000))
  done
  rm -f "$del"
}

cmd_down() {
  require_env
  [[ -f "$STATE_FILE" ]] || die "nothing to tear down"
  printf 'Destroy lab resources described in %s? [y/N] ' "$STATE_FILE" >&2
  read -r ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted"

  # Prefer explicit --region; also pin AWS_REGION so it cannot stick on a prior Region.
  wait_vpce_gone() {
    local region="$1" vid="$2" i state
    [[ -n "$vid" ]] || return 0
    for i in $(seq 1 36); do
      state="$(aws ec2 describe-vpc-endpoints --region "$region" --vpc-endpoint-ids "$vid" \
        --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo gone)"
      [[ "$state" == "gone" || "$state" == "None" || -z "$state" ]] && return 0
      sleep 5
    done
    printf 'warn: VPCE %s still %s in %s\n' "$vid" "$state" "$region" >&2
  }

  for which in syd akl; do
    local iid region role sg_ec2 sg_ssm created sv vpc subnet rtb created_vpc
    iid="$(jq -r --arg w "$which" '.consumers[$w].instance_id // empty' "$STATE_FILE")"
    [[ -n "$iid" ]] || continue
    region="$(jq -r --arg w "$which" '.consumers[$w].region' "$STATE_FILE")"
    role="$(jq -r --arg w "$which" '.consumers[$w].role_name' "$STATE_FILE")"
    sg_ec2="$(jq -r --arg w "$which" '.consumers[$w].sg_ec2' "$STATE_FILE")"
    sg_ssm="$(jq -r --arg w "$which" '.consumers[$w].sg_ssm' "$STATE_FILE")"
    created="$(jq -r --arg w "$which" '.consumers[$w].created_s3_vpce' "$STATE_FILE")"
    created_vpc="$(jq -r --arg w "$which" '.consumers[$w].created_vpc // false' "$STATE_FILE")"
    vpc="$(jq -r --arg w "$which" '.consumers[$w].vpc_id // empty' "$STATE_FILE")"
    subnet="$(jq -r --arg w "$which" '.consumers[$w].subnet_id // empty' "$STATE_FILE")"
    rtb="$(jq -r --arg w "$which" '.consumers[$w].route_table_id // empty' "$STATE_FILE")"
    export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
    printf 'tearing down consumer %s in %s\n' "$which" "$region" >&2

    run aws ec2 terminate-instances --region "$region" --instance-ids "$iid" || true
    run aws ec2 wait instance-terminated --region "$region" --instance-ids "$iid" || true

    local vids=()
    while read -r vid; do
      [[ -n "$vid" ]] || continue
      vids+=("$vid")
      run aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$vid" || true
    done < <(jq -r --arg w "$which" '.consumers[$w].ssm_vpce_ids[]?' "$STATE_FILE")
    if [[ "$created" == "true" ]]; then
      sv="$(jq -r --arg w "$which" '.consumers[$w].s3_vpce_id' "$STATE_FILE")"
      vids+=("$sv")
      run aws ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$sv" || true
    fi
    for vid in "${vids[@]}"; do
      wait_vpce_gone "$region" "$vid"
    done

    run aws ec2 delete-security-group --region "$region" --group-id "$sg_ec2" || true
    run aws ec2 delete-security-group --region "$region" --group-id "$sg_ssm" || true
    run aws iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role" || true
    run aws iam delete-instance-profile --instance-profile-name "$role" || true
    run aws iam delete-role-policy --role-name "$role" --policy-name artifact-read || true
    run aws iam detach-role-policy --role-name "$role" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
    run aws iam delete-role --role-name "$role" || true

    if [[ "$created_vpc" == "true" ]]; then
      if [[ -n "$rtb" ]]; then
        while read -r assoc; do
          [[ -n "$assoc" && "$assoc" != "None" ]] && \
            run aws ec2 disassociate-route-table --region "$region" --association-id "$assoc" || true
        done < <(aws ec2 describe-route-tables --region "$region" --route-table-ids "$rtb" \
          --query 'RouteTables[0].Associations[?SubnetId!=null].RouteTableAssociationId' \
          --output text 2>/dev/null | tr '\t' '\n')
      fi
      local i
      for i in 1 2 3 4 5 6; do
        [[ -n "$subnet" ]] && run aws ec2 delete-subnet --region "$region" --subnet-id "$subnet" && subnet="" || true
        [[ -n "$rtb" ]] && run aws ec2 delete-route-table --region "$region" --route-table-id "$rtb" && rtb="" || true
        [[ -n "$vpc" ]] && run aws ec2 delete-vpc --region "$region" --vpc-id "$vpc" && vpc="" || true
        [[ -z "$subnet" && -z "$rtb" && -z "$vpc" ]] && break
        sleep 5
      done
      [[ -z "$vpc" ]] || printf 'warn: VPC %s may still exist in %s\n' "$vpc" "$region" >&2
    fi
  done

  local primary replica role_arn role_name
  primary="$(state_get .primary_bucket)"
  replica="$(state_get .replica_bucket)"
  role_arn="$(state_get .crr_role_arn)"
  [[ "$primary" == "null" ]] && primary=""
  [[ "$replica" == "null" ]] && replica=""
  [[ "$role_arn" == "null" ]] && role_arn=""
  role_name="${role_arn##*/}"
  export AWS_REGION="$PRIMARY_REGION" AWS_DEFAULT_REGION="$PRIMARY_REGION"
  if [[ -n "$primary" ]]; then
    run aws s3api delete-bucket-replication --bucket "$primary" --region "$PRIMARY_REGION" || true
    empty_bucket "$primary" "$PRIMARY_REGION"
    run aws s3api delete-bucket --bucket "$primary" --region "$PRIMARY_REGION" || true
  fi
  if [[ -n "$replica" ]]; then
    empty_bucket "$replica" "$REPLICA_REGION"
    run aws s3api delete-bucket --bucket "$replica" --region "$REPLICA_REGION" || true
  fi
  if [[ -n "$role_name" ]]; then
    run aws iam delete-role-policy --role-name "$role_name" --policy-name crr || true
    run aws iam delete-role --role-name "$role_name" || true
  fi
  rm -f "$STATE_FILE"
  printf 'down complete\n' >&2
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up-shared) cmd_up_shared "$@" ;;
    up-consumer) cmd_up_consumer "$@" ;;
    allowlist) cmd_allowlist "$@" ;;
    publish) cmd_publish "$@" ;;
    prove) cmd_prove "$@" ;;
    status) cmd_status "$@" ;;
    down) cmd_down "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
