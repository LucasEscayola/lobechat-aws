#!/usr/bin/env bash
# Deploys LobeChat on a single EC2 instance in eu-west-1.
# Prerequisites: AWS CLI configured with EC2FullAccess, jq in PATH.
# Run from the repo root or infra/ directory.

set -euo pipefail

REGION="eu-west-1"
KEY_NAME="lobechat-key"
SG_NAME="lobechat-sg"
TAG="lobechat-final"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== LobeChat EC2 Deployment (${REGION}) ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Resolve latest Ubuntu 24.04 AMI via EC2 describe-images (Canonical)
# ---------------------------------------------------------------------------
echo "[1/7] Fetching latest Ubuntu 24.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
    "Name=state,Values=available" \
    "Name=architecture,Values=x86_64" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text \
  --region "$REGION")
echo "      AMI: ${AMI_ID}"

# ---------------------------------------------------------------------------
# 2. Create security group (idempotent)
# ---------------------------------------------------------------------------
echo "[2/7] Ensuring security group '${SG_NAME}' exists..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region "$REGION")

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region "$REGION" 2>/dev/null)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "LobeChat - allow SSH, HTTP, HTTPS" \
    --region "$REGION" \
    --query "GroupId" \
    --output text)
  echo "      SG created: ${SG_ID}"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --ip-permissions \
      "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description=SSH}]" \
      "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]" \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS}]" \
    --region "$REGION" \
    --output text > /dev/null

  aws ec2 create-tags \
    --resources "$SG_ID" \
    --tags "Key=Name,Value=${TAG}" \
    --region "$REGION"
else
  echo "      SG already exists: ${SG_ID}"
fi

# ---------------------------------------------------------------------------
# 3. Create key pair (idempotent)
# ---------------------------------------------------------------------------
echo "[3/7] Ensuring key pair '${KEY_NAME}' exists..."
mkdir -p ~/.ssh
if aws ec2 describe-key-pairs \
     --key-names "$KEY_NAME" \
     --no-cli-pager \
     --region "$REGION" \
     --output text > /dev/null 2>&1; then
  # Key exists in AWS
  if [ ! -f ~/.ssh/lobechat-key.pem ]; then
    echo "      ERROR: key pair '${KEY_NAME}' exists in AWS but ~/.ssh/lobechat-key.pem is missing locally."
    exit 1
  fi
  echo "      Key pair already exists, using existing pem"
else
  # Key does not exist in AWS — create it
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --no-cli-pager \
    --query "KeyMaterial" \
    --output text \
    --region "$REGION" > ~/.ssh/lobechat-key.pem
  chmod 600 ~/.ssh/lobechat-key.pem
  echo "      Key pair created → ~/.ssh/lobechat-key.pem"

  KEY_PAIR_ID=$(aws ec2 describe-key-pairs \
    --key-names "$KEY_NAME" \
    --no-cli-pager \
    --query "KeyPairs[0].KeyPairId" \
    --output text \
    --region "$REGION")
  aws ec2 create-tags \
    --resources "$KEY_PAIR_ID" \
    --no-cli-pager \
    --tags "Key=Name,Value=${TAG}" \
    --region "$REGION"
fi

# ---------------------------------------------------------------------------
# 4. Launch instance — t3.xlarge, 60 GB gp3, Ubuntu 24.04
# ---------------------------------------------------------------------------
echo "[4/7] Launching t3.xlarge with 60 GB gp3..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "t3.xlarge" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --user-data "file://${SCRIPT_DIR}/userdata.sh" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${TAG}}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${TAG}}]" \
  --region "$REGION" \
  --query "Instances[0].InstanceId" \
  --output text)
echo "      Instance: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# 5. Wait for running state
# ---------------------------------------------------------------------------
echo "[5/7] Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"
echo "      Running."

# ---------------------------------------------------------------------------
# 6. Allocate Elastic IP and associate
# ---------------------------------------------------------------------------
echo "[6/7] Allocating and associating Elastic IP..."
ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --region "$REGION" \
  --query "AllocationId" \
  --output text)

aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "$ALLOC_ID" \
  --region "$REGION" \
  --output text > /dev/null

aws ec2 create-tags \
  --resources "$ALLOC_ID" \
  --tags "Key=Name,Value=${TAG}" \
  --region "$REGION"

# ---------------------------------------------------------------------------
# 7. Collect and print deployment summary
# ---------------------------------------------------------------------------
echo "[7/7] Collecting deployment details..."
PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$ALLOC_ID" \
  --query "Addresses[0].PublicIp" \
  --output text \
  --region "$REGION")

PUBLIC_DNS=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicDnsName" \
  --output text \
  --region "$REGION")

echo ""
echo "============================================"
echo "  Deployment complete"
echo "============================================"
echo "  Instance ID : ${INSTANCE_ID}"
echo "  Public IP   : ${PUBLIC_IP}"
echo "  Public DNS  : ${PUBLIC_DNS}"
echo "============================================"
echo ""
echo "SSH access:"
echo "  ssh -i ~/.ssh/lobechat-key.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "Point DuckDNS to ${PUBLIC_IP}, then monitor boot:"
echo "  ssh -i ~/.ssh/lobechat-key.pem ubuntu@${PUBLIC_IP} 'sudo tail -f /var/log/cloud-init-output.log'"
