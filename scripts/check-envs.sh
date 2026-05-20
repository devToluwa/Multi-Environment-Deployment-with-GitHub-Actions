#!/bin/bash

CLUSTER="multi-env-deploy"
ENVIRONMENTS=("dev" "staging" "prod")

for ENV in "${ENVIRONMENTS[@]}"; do
  echo "========================================="
  echo "Environment: $ENV"
  echo "========================================="

  TASK_ARN=$(aws ecs list-tasks \
    --cluster $CLUSTER \
    --service-name multi-env-deploy-$ENV \
    --query 'taskArns[0]' \
    --output text)

  if [ "$TASK_ARN" == "None" ] || [ -z "$TASK_ARN" ]; then
    echo "No running tasks found for $ENV"
    echo ""
    continue
  fi

  echo "Task ARN: $TASK_ARN"

  ENI_ID=$(aws ecs describe-tasks \
    --cluster $CLUSTER \
    --tasks $TASK_ARN \
    --output json | grep -A1 '"networkInterfaceId"' | grep '"value"' | cut -d'"' -f4)

  echo "ENI: $ENI_ID"

  PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids $ENI_ID \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text)

  echo "Public IP: $PUBLIC_IP"
  echo ""

  echo "--- curl http://$PUBLIC_IP:5000 ---"
  curl -s http://$PUBLIC_IP:5000
  echo ""

  echo "--- curl http://$PUBLIC_IP:5000/health ---"
  curl -s http://$PUBLIC_IP:5000/health
  echo ""
  echo ""
done