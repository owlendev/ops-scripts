#!/usr/bin/env bash
# Run FROM YOUR MACHINE (needs AWS CLI v2 configured).
# Creates a security group (SSH from your IP, HTTP/HTTPS from anywhere),
# launches the latest Ubuntu LTS, waits for SSH, then runs bootstrap.sh on it
# via tools/push-and-run.sh.
#
#   tools/ec2-launch.sh --name acme-web --key-name acme --key-file ~/.ssh/acme.pem --config clients/acme.env
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$OPS_ROOT/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 --name NAME --key-name KEY --key-file PEM [options]

Required:
  --name NAME          Instance name (Name tag). Also used for the security group: NAME-sg
  --key-name KEY       Existing EC2 key pair name (aws ec2 describe-key-pairs)
  --key-file PEM       Matching private key on this machine (needed to run bootstrap)

Options:
  --config FILE        Client config for bootstrap.sh (also read for SSH_PORT)
  --type TYPE          Instance type (default t3.small; Graviton e.g. t4g.small is detected)
  --ubuntu VERSION     Ubuntu LTS version (default 24.04)
  --disk GB            Root volume size in GB (default 20)
  --region REGION      AWS region (default: your AWS CLI default)
  --subnet-id ID       Launch into this subnet (default: default VPC)
  --ssh-cidr CIDR      Who may SSH in (default: your current public IP/32)
  --eip                Allocate and attach an Elastic IP (stable IP for DNS)
  --no-bootstrap       Launch only; don't run bootstrap.sh (--key-file not needed)
  -h, --help           Show this help

Uses your AWS CLI credentials/profile (set AWS_PROFILE to choose one).
EOF
}

NAME=""; KEY_NAME=""; KEY_FILE=""; CONFIG=""; TYPE="t3.small"; UBUNTU="24.04"; DISK=20
SUBNET_ID=""; SSH_CIDR=""; EIP=0; BOOTSTRAP=1
LOGIN_USER=ubuntu
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2 ;;
    --key-name)     KEY_NAME="$2"; shift 2 ;;
    --key-file)     KEY_FILE="$2"; shift 2 ;;
    --config)       CONFIG="$2"; shift 2 ;;
    --type)         TYPE="$2"; shift 2 ;;
    --ubuntu)       UBUNTU="$2"; shift 2 ;;
    --disk)         DISK="$2"; shift 2 ;;
    --region)       export AWS_REGION="$2"; shift 2 ;;
    --subnet-id)    SUBNET_ID="$2"; shift 2 ;;
    --ssh-cidr)     SSH_CIDR="$2"; shift 2 ;;
    --eip)          EIP=1; shift ;;
    --no-bootstrap) BOOTSTRAP=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "Unknown option: $1" ;;
  esac
done
[[ -n "$NAME" && -n "$KEY_NAME" ]] || { usage >&2; exit 1; }
if (( BOOTSTRAP )); then
  [[ -n "$KEY_FILE" ]] || die "--key-file is required to run the bootstrap (or pass --no-bootstrap)."
  [[ -f "$KEY_FILE" ]] || die "Key file not found: $KEY_FILE"
fi
[[ -z "$CONFIG" || -f "$CONFIG" ]] || die "Config not found: $CONFIG"
command -v aws >/dev/null || die "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

aws sts get-caller-identity --query Account --output text >/dev/null || die "AWS CLI is not authenticated."
REGION="${AWS_REGION:-$(aws configure get region || true)}"
[[ -n "$REGION" ]] || die "No region. Pass --region or run 'aws configure'."
export AWS_REGION="$REGION"

existing=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[[ -z "$existing" ]] || die "An instance named '$NAME' already exists: $existing"

# SSH port the server will end up on, from the client config.
SSH_PORT=$(
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$OPS_ROOT/config/default.env"
  # shellcheck disable=SC1090
  [[ -n "$CONFIG" ]] && . "$CONFIG"
  echo "$SSH_PORT"
)

if [[ -z "$SSH_CIDR" ]]; then
  myip=$(curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')
  [[ "$myip" =~ ^[0-9.]+$ ]] || die "Could not detect your public IP. Pass --ssh-cidr."
  SSH_CIDR="$myip/32"
fi

# Graviton (arm64) types have a 'g' after the generation number: t4g, m7g, c7gn...
ARCH=amd64
[[ "$TYPE" =~ ^[a-z]+[0-9]+[a-z]*g[a-z]*\. ]] && ARCH=arm64

section "Launching '$NAME' in $REGION"

# --- AMI --------------------------------------------------------------------
AMI=$(aws ssm get-parameter \
  --name "/aws/service/canonical/ubuntu/server/$UBUNTU/stable/current/$ARCH/hvm/ebs-gp3/ami-id" \
  --query Parameter.Value --output text 2>/dev/null) \
  || AMI=$(aws ssm get-parameter \
  --name "/aws/service/canonical/ubuntu/server/$UBUNTU/stable/current/$ARCH/hvm/ebs-gp2/ami-id" \
  --query Parameter.Value --output text) \
  || die "Could not find an Ubuntu $UBUNTU $ARCH AMI."
ROOT_DEV=$(aws ec2 describe-images --image-ids "$AMI" --query 'Images[0].RootDeviceName' --output text)
info "AMI: $AMI (Ubuntu $UBUNTU, $ARCH)"

# --- Network / security group -----------------------------------------------
if [[ -n "$SUBNET_ID" ]]; then
  VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
else
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC_ID" != "None" ]] || die "No default VPC in $REGION. Pass --subnet-id."
fi

SG_NAME="$NAME-sg"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "ops-scripts: $NAME" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=ManagedBy,Value=ops-scripts}]" \
    --query GroupId --output text)
  info "Created security group $SG_NAME ($SG_ID)"
else
  info "Reusing security group $SG_NAME ($SG_ID)"
fi

allow() { # proto port cidr description
  local family=IpRanges key=CidrIp
  [[ "$3" == *:* ]] && family=Ipv6Ranges key=CidrIpv6
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=$1,FromPort=$2,ToPort=$2,$family=[{$key=$3,Description=\"$4\"}]" \
    >/dev/null 2>&1 || true   # already exists
}
allow tcp "$SSH_PORT" "$SSH_CIDR" "SSH"
# A fresh instance listens on 22 until bootstrap moves sshd.
[[ "$SSH_PORT" != "22" ]] && allow tcp 22 "$SSH_CIDR" "SSH initial - remove after bootstrap"
for cidr in 0.0.0.0/0 ::/0; do
  allow tcp 80 "$cidr" "HTTP"
  allow tcp 443 "$cidr" "HTTPS"
done
info "Ingress: SSH $SSH_PORT from $SSH_CIDR; HTTP/HTTPS from anywhere"

# --- Launch -----------------------------------------------------------------
launch_args=()
[[ -n "$SUBNET_ID" ]] && launch_args+=(--subnet-id "$SUBNET_ID")

tags="{Key=Name,Value=$NAME},{Key=ManagedBy,Value=ops-scripts}"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI" \
  --instance-type "$TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
  --block-device-mappings "DeviceName=$ROOT_DEV,Ebs={VolumeSize=$DISK,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=instance,Tags=[$tags]" "ResourceType=volume,Tags=[$tags]" \
  ${launch_args[@]+"${launch_args[@]}"} \
  --query 'Instances[0].InstanceId' --output text)
ok "Launched $INSTANCE_ID ($TYPE)"

info "Waiting for the instance to be running"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

if (( EIP )); then
  ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[$tags]" \
    --query AllocationId --output text)
  aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
  info "Attached Elastic IP ($ALLOC_ID)"
fi

IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
[[ "$IP" != "None" ]] || die "Instance has no public IP (subnet doesn't auto-assign one). Use --eip."
ok "Public IP: $IP"

if (( ! BOOTSTRAP )); then
  section "Done"
  cat <<EOF
  Instance:  $INSTANCE_ID   Region: $REGION   IP: $IP

  Prepare it when ready:
    tools/push-and-run.sh -i <your-key.pem> ${CONFIG:+-c $CONFIG }$LOGIN_USER@$IP
EOF
  exit 0
fi

# --- Bootstrap --------------------------------------------------------------
ssh_opts=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)
info "Waiting for SSH on $IP:22"
for _ in $(seq 1 60); do
  ssh "${ssh_opts[@]}" "$LOGIN_USER@$IP" true 2>/dev/null && break
  sleep 5
done
ssh "${ssh_opts[@]}" "$LOGIN_USER@$IP" true || die "SSH did not come up after 5 minutes."

# First boot: let cloud-init finish so we don't fight it for the apt lock.
info "Waiting for cloud-init to finish"
ssh "${ssh_opts[@]}" "$LOGIN_USER@$IP" 'cloud-init status --wait >/dev/null' || true

"$OPS_ROOT/tools/push-and-run.sh" -i "$KEY_FILE" ${CONFIG:+-c "$CONFIG"} "$LOGIN_USER@$IP"

section "Ready"
cat <<EOF
  Instance:  $INSTANCE_ID   Region: $REGION   IP: $IP
  Connect:   ssh -i $KEY_FILE -p $SSH_PORT $LOGIN_USER@$IP
  Destroy:   tools/ec2-terminate.sh --name $NAME
EOF
[[ "$SSH_PORT" != "22" ]] && warn "Remove the port 22 rule from security group $SG_NAME now that SSH moved to $SSH_PORT."
exit 0
