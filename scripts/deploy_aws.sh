#!/usr/bin/env bash
# Deploy ParkinsonLife to AWS ECS Fargate with an Application Load Balancer.
# Run from anywhere — finds the repo root automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="parkinsonlife"
ALB_NAME="${APP}-alb"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${APP}"

echo "==> Account: ${ACCOUNT}  Region: ${REGION}"

# ── 1. ECR login & repo ────────────────────────────────────────────────────────
echo "==> Logging into ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Ensuring ECR repository..."
aws ecr describe-repositories --repository-names "$APP" --region "$REGION" \
  >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$APP" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true >/dev/null

# ── 2. Build & push ────────────────────────────────────────────────────────────
echo "==> Building Docker image..."
docker build --platform linux/amd64 -t "${APP}:latest" "$REPO_ROOT"

echo "==> Pushing to ECR..."
docker tag "${APP}:latest" "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"

# ── 3. Networking — default VPC ───────────────────────────────────────────────
echo "==> Resolving default VPC and subnets..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true \
  --query "Vpcs[0].VpcId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[*].SubnetId" --output text | tr '\t' ',')

echo "    VPC: ${VPC_ID}"
echo "    Subnets: ${SUBNET_IDS}"

# ── 4. Security groups ────────────────────────────────────────────────────────
echo "==> Ensuring security groups..."

ALB_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-alb" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")

if [ "$ALB_SG" = "None" ] || [ -z "$ALB_SG" ]; then
  ALB_SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${APP}-alb" \
    --description "ALB security group for ${APP}" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
  echo "    Created ALB SG: ${ALB_SG}"
else
  echo "    ALB SG exists: ${ALB_SG}"
fi

TASK_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-task" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")

if [ "$TASK_SG" = "None" ] || [ -z "$TASK_SG" ]; then
  TASK_SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${APP}-task" \
    --description "Task security group for ${APP}" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$TASK_SG" --protocol tcp --port 80 --source-group "$ALB_SG" >/dev/null
  echo "    Created Task SG: ${TASK_SG}"
else
  echo "    Task SG exists: ${TASK_SG}"
fi

# ── 5. ECS cluster ────────────────────────────────────────────────────────────
echo "==> Ensuring ECS cluster..."
aws ecs describe-clusters --region "$REGION" --clusters "$APP" \
  --query "clusters[?status=='ACTIVE'].clusterName" --output text | grep -q "$APP" || \
  aws ecs create-cluster --region "$REGION" --cluster-name "$APP" \
    --capacity-providers FARGATE >/dev/null
echo "    Cluster: ${APP}"

# ── 6. CloudWatch log group ───────────────────────────────────────────────────
echo "==> Ensuring CloudWatch log group..."
aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/ecs/${APP}" \
  --query "logGroups[0].logGroupName" --output text | grep -q "/ecs/${APP}" || \
  aws logs create-log-group --region "$REGION" --log-group-name "/ecs/${APP}"

# ── 7. IAM execution role ─────────────────────────────────────────────────────
echo "==> Ensuring ECS task execution role..."
EXEC_ROLE_NAME="${APP}-ecs-execution-role"
if ! aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Principal":{"Service":"ecs-tasks.amazonaws.com"},
        "Action":"sts:AssumeRole"
      }]
    }' >/dev/null
  aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  echo "    Waiting for IAM role to propagate..."
  sleep 12
fi
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE_NAME}"

# ── 8. Task definition ────────────────────────────────────────────────────────
echo "==> Registering task definition..."
TASK_DEF_JSON=$(python3 -c "
import json
print(json.dumps({
  'family': '${APP}',
  'networkMode': 'awsvpc',
  'requiresCompatibilities': ['FARGATE'],
  'cpu': '256',
  'memory': '512',
  'executionRoleArn': '${EXEC_ROLE_ARN}',
  'containerDefinitions': [{
    'name': '${APP}',
    'image': '${ECR_REPO}:latest',
    'portMappings': [{'containerPort': 80, 'protocol': 'tcp'}],
    'essential': True,
    'logConfiguration': {
      'logDriver': 'awslogs',
      'options': {
        'awslogs-group': '/ecs/${APP}',
        'awslogs-region': '${REGION}',
        'awslogs-stream-prefix': 'ecs'
      }
    }
  }]
}))
")

TASK_DEF_ARN=$(aws ecs register-task-definition --region "$REGION" \
  --cli-input-json "$TASK_DEF_JSON" \
  --query "taskDefinition.taskDefinitionArn" --output text)
echo "    Task def: ${TASK_DEF_ARN}"

# ── 9. ALB ────────────────────────────────────────────────────────────────────
echo "==> Ensuring Application Load Balancer..."
SUBNET_LIST=$(echo "$SUBNET_IDS" | tr ',' ' ')

ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer --region "$REGION" \
    --name "$ALB_NAME" \
    --subnets $SUBNET_LIST \
    --security-groups "$ALB_SG" \
    --scheme internet-facing \
    --type application \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
  echo "    Created ALB: ${ALB_ARN}"
else
  echo "    ALB exists: ${ALB_ARN}"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)

# ── 10. Target group ──────────────────────────────────────────────────────────
echo "==> Ensuring target group..."
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "${APP}-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
    --name "${APP}-tg" \
    --protocol HTTP --port 80 \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  echo "    Created TG: ${TG_ARN}"
else
  echo "    TG exists: ${TG_ARN}"
fi

# ── 11. Listener ──────────────────────────────────────────────────────────────
echo "==> Ensuring ALB listener..."
LISTENER_ARN=$(aws elbv2 describe-listeners --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text 2>/dev/null || echo "")

if [ -z "$LISTENER_ARN" ]; then
  aws elbv2 create-listener --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
  echo "    Created listener on port 80"
else
  echo "    Listener exists"
fi

# ── 12. ECS service ───────────────────────────────────────────────────────────
echo "==> Ensuring ECS service..."
SUBNET_JSON=$(python3 -c "import json; print(json.dumps('${SUBNET_IDS}'.split(',')))")

NETWORK_CONFIG=$(python3 -c "
import json
print(json.dumps({
  'awsvpcConfiguration': {
    'subnets': '${SUBNET_IDS}'.split(','),
    'securityGroups': ['${TASK_SG}'],
    'assignPublicIp': 'ENABLED'
  }
}))
")

LB_CONFIG="[{\"targetGroupArn\":\"${TG_ARN}\",\"containerName\":\"${APP}\",\"containerPort\":80}]"

SERVICE_EXISTS=$(aws ecs describe-services --region "$REGION" \
  --cluster "$APP" --services "$APP" \
  --query "services[?status=='ACTIVE'].serviceName" --output text 2>/dev/null || echo "")

if [ -z "$SERVICE_EXISTS" ]; then
  aws ecs create-service --region "$REGION" \
    --cluster "$APP" \
    --service-name "$APP" \
    --task-definition "$APP" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG" \
    --load-balancers "$LB_CONFIG" >/dev/null
  echo "    Created ECS service"
else
  aws ecs update-service --region "$REGION" \
    --cluster "$APP" \
    --service "$APP" \
    --task-definition "$APP" \
    --force-new-deployment >/dev/null
  echo "    Updated ECS service (forced new deployment)"
fi

echo ""
echo "================================================================"
echo "  Deployment triggered!"
echo "  URL: http://${ALB_DNS}"
echo ""
echo "  Wait ~2 min for the task to start and pass health checks."
echo "  Status: aws ecs describe-services --cluster ${APP} --services ${APP} --region ${REGION}"
echo "================================================================"
