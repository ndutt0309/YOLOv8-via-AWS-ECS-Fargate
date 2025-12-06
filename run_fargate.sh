#!/bin/bash
set -e

# ===== USER CONFIGURATION =====
REGION="us-east-1"                      # change if needed
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/yolo-api:amd64-20251104"  
CONTAINER_PORT=8080                     

CLUSTER_NAME="temp-fargate-cluster"
TASK_FAMILY="temp-fargate-task"
SECURITY_GROUP_NAME="temp-fargate-sg"
ROLE_NAME="ecsTaskExecutionRole"
ALB_NAME="temp-fargate-alb"
TG_NAME="temp-fargate-target-group"
DASHBOARD_NAME="YOLOv8Dashboard"

echo "🔹 Using account: $ACCOUNT_ID in region: $REGION"
echo "🔹 Image: $ECR_IMAGE_URI"
echo "🔹 Port: $CONTAINER_PORT"

# ===== CREATE CLUSTER =====
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters $CLUSTER_NAME \
  --region $REGION \
  --query "clusters[0].status" \
  --output text 2>/dev/null)

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
  aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $REGION > /dev/null
  echo "✅ ECS cluster created: $CLUSTER_NAME"
else
  echo "✅ Using existing ECS cluster: $CLUSTER_NAME"
fi


# ===== CREATE IAM ROLE & POLICY =====
if ! aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
  cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  aws iam create-role --role-name $ROLE_NAME \
      --assume-role-policy-document file://trust-policy.json > /dev/null
  aws iam attach-role-policy \
      --role-name $ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  echo "✅ IAM role created: $ROLE_NAME"
else
  echo "✅ Using existing IAM role: $ROLE_NAME"
fi

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query "Role.Arn" --output text)

# ===== NETWORK SETUP =====
# 1️⃣ Get default VPC (or first VPC)
VPC_ID=$(aws ec2 describe-vpcs --query "Vpcs[0].VpcId" --output text)
echo "✅ Using default VPC: $VPC_ID"

# Get VPC CIDR block and base prefix (e.g., 172.31)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[0].CidrBlock" --output text)
BASE_PREFIX=$(echo "$VPC_CIDR" | cut -d'.' -f1,2)

# Get or create first public subnet
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" --query "Subnets[0].SubnetId" --output text)
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
    AVAIL_ZONE=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
    SUBNET_CIDR=${BASE_PREFIX}.0.0/24
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --availability-zone $AVAIL_ZONE --query "Subnet.SubnetId" --output text)
    aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch
    echo "✅ Created first subnet: $SUBNET_ID ($AVAIL_ZONE) with CIDR $SUBNET_CIDR"

     # Create Internet Gateway if none exists
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text)
    if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "None" ]; then
        IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text)
        aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID > /dev/null 2>&1
    fi

    # Create a route table and associate with subnet
    ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
    aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID > /dev/null 2>&1
else
    echo "✅ Using existing first subnet: $SUBNET_ID"

    # Get existing IGW
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query "InternetGateways[0].InternetGatewayId" --output text)

    # Get route table associated with this subnet
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
        --query "RouteTables[0].RouteTableId" --output text)
fi

# Ensure second public subnet exists
SUBNET_ID2=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" --query "Subnets[1].SubnetId" --output text)
if [ -z "$SUBNET_ID2" ] || [ "$SUBNET_ID2" = "None" ]; then
    AVAIL_ZONE2=$(aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text)
    SUBNET_CIDR2=${BASE_PREFIX}.1.0/24
    SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AVAIL_ZONE2 --query "Subnet.SubnetId" --output text)
    aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch

    if [ -z "$ROUTE_TABLE_ID" ]; then
      ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "RouteTables[?Associations[?Main==\`true\`]].RouteTableId | [0]" \
        --output text)
    fi
    aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID > /dev/null 2>&1 
    echo "✅ Created second subnet: $SUBNET_ID2 ($AVAIL_ZONE2) with CIDR $SUBNET_CIDR2"
else
    echo "✅ Using existing second subnet: $SUBNET_ID2"
fi

# 3️⃣ Check/create Security Group
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "Temp Fargate SG" \
        --vpc-id $VPC_ID \
        --query "GroupId" \
        --output text)
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port $CONTAINER_PORT \
        --cidr 0.0.0.0/0 >/dev/null 2>&1
    echo "✅ Created security group: $SG_ID"
else
    echo "✅ Using existing security group: $SG_ID"
fi

# ===== LOAD BALANCER =====

# Create Target Group, where the load balancer will route traffic to
TG_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
    TG_ARN=$(aws elbv2 create-target-group \
        --name $TG_NAME \
        --protocol HTTP \
        --port $CONTAINER_PORT \
        --vpc-id $VPC_ID \
        --target-type ip \
        --health-check-protocol HTTP \
        --health-check-port $CONTAINER_PORT \
        --health-check-path /healthz \
        --health-check-interval-seconds 10 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 2 \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text)
    echo "✅ Target group created: $TG_ARN"
else
    echo "✅ Using existing target group: $TG_ARN"
fi


# Create the Application Load Balancer
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names $ALB_NAME \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name $ALB_NAME \
        --subnets $SUBNET_ID $SUBNET_ID2 \
        --security-groups $SG_ID \
        --scheme internet-facing \
        --type application \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text)
    echo "✅ ALB created: $ALB_ARN"
else
    echo "✅ Using existing ALB: $ALB_ARN"
fi

# Create Listener to forward the traffic to the Target Group
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query "Listeners[0].ListenerArn" \
  --output text 2>/dev/null || echo "")

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    LISTENER_ARN=$(aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port $CONTAINER_PORT \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --query "Listeners[0].ListenerArn" \
        --output text)
    echo "✅ ALB Listener created: $LISTENER_ARN"
else
    echo "✅ Using existing ALB Listener: $LISTENER_ARN"
fi

# ===== TASK DEFINITION =====
cat > task-def.json <<EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "$ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "my-app",
      "image": "$ECR_IMAGE_URI",
      "portMappings": [
        {
          "containerPort": $CONTAINER_PORT,
          "protocol": "tcp"
        }
      ],
      "essential": true
    }
  ]
}
EOF

# Check if a task definition with this family already exists
EXISTING=$(aws ecs list-task-definitions \
    --family-prefix "$TASK_FAMILY" \
    --region "$REGION" \
    --query 'taskDefinitionArns[-1]' \
    --output text 2>/dev/null)

if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
    echo "📦 Registering new task definition: $TASK_FAMILY"
    aws ecs register-task-definition \
        --cli-input-json file://task-def.json \
        --region "$REGION" > /dev/null
    echo "✅ Task definition registered."
else
    echo "✅ Task definition already exists: $EXISTING"
fi

#echo "📦 Registering task definition..."
#aws ecs register-task-definition --cli-input-json file://task-def.json --region $REGION > /dev/null

## ===== ECS SERVICE =====

# Create ECS Service to run and maintain desired number of tasks (dynamic)
SERVICE_NAME="${CLUSTER_NAME}-service"

SERVICE_ARN=$(aws ecs describe-services \
  --cluster $CLUSTER_NAME \
  --services $SERVICE_NAME \
  --query "services[0].serviceArn" \
  --output text 2>/dev/null)

SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --query "services[0].status" \
  --output text 2>/dev/null)

if [ -z "$SERVICE_STATUS" ] || [ "$SERVICE_STATUS" = "None" ] || [ "$SERVICE_STATUS" = "null" ] || [ "$SERVICE_STATUS" = "INACTIVE" ]; then
    SERVICE_ARN=$(aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --task-definition "$TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID,$SUBNET_ID2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=my-app,containerPort=$CONTAINER_PORT" \
        --deployment-controller type=ECS \
        --query "service.serviceArn" \
        --output text)
    echo "✅ ECS service created: $SERVICE_ARN"
else
    echo "✅ Using existing ECS service: $SERVICE_ARN (status: $SERVICE_STATUS)"
fi



echo "⏳ Waiting 5 minutes for ECS tasks to become healthy in the Target Group..."
for i in {1..15}; do
    HEALTH=$(aws elbv2 describe-target-health \
        --target-group-arn $TG_ARN \
        --query 'TargetHealthDescriptions[*].TargetHealth.State' \
        --output text 2>/dev/null)

    if [[ "$HEALTH" == *"healthy"* ]]; then
        echo "✅ Target(s) are healthy!"
        break
    else
        echo "🔄 Still waiting... (attempt $i)"
        sleep 20
    fi
done

if [[ "$HEALTH" != *"healthy"* ]]; then
    echo "❌ Targets did not become healthy after 5 minutes. Continue monitoring health on AWS Console (it may take longer) or check for any errors."
fi


## ===== AUTOSCALING =====

echo "📈 Configuring target tracking auto scaling for ECS service..."

aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/$SERVICE_NAME \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 20 > /dev/null

ALB_ARN_SUFFIX=$(echo $ALB_ARN | awk -F'loadbalancer/' '{print $2}')
TG_ARN_SUFFIX=$(echo $TG_ARN | awk -F'targetgroup/' '{print $2}')

RESOURCE_LABEL="$ALB_ARN_SUFFIX/targetgroup/$TG_ARN_SUFFIX"

# Request Count per Target Scaling Policy
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/$SERVICE_NAME \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name "RequestCountPolicy" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 50,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ALBRequestCountPerTarget\",\"ResourceLabel\": \"$RESOURCE_LABEL\"},
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 60
  }" > /dev/null

# CPU Utilization Scaling Policy
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/$SERVICE_NAME \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name "CPUPolicy" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 60.0,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"},
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 60
  }" > /dev/null

## ==== LATENCY CLOUD WATCH + SCALING POLICY =====
echo "📈 Configuring step auto scaling for ECS service..."

# Step Scaling Policies
SCALE_OUT_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/$SERVICE_NAME \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name HighLatencyScaleOutPolicy \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
      "AdjustmentType": "ChangeInCapacity",
      "StepAdjustments": [
        { "MetricIntervalLowerBound": 0.0, "MetricIntervalUpperBound": 0.2, "ScalingAdjustment": 1 },
        { "MetricIntervalLowerBound": 0.2, "MetricIntervalUpperBound": 0.8, "ScalingAdjustment": 2 },
        { "MetricIntervalLowerBound": 0.8, "ScalingAdjustment": 3 }
      ],
      "Cooldown": 60,
      "MetricAggregationType": "Average"
  }' --query "PolicyARN" --output text)


SCALE_IN_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/$CLUSTER_NAME/$SERVICE_NAME \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name LowLatencyScaleInPolicy \
  --policy-type StepScaling \
  --step-scaling-policy-configuration '{
      "AdjustmentType": "ChangeInCapacity",
      "StepAdjustments": [
        {"MetricIntervalUpperBound": 0.3, "ScalingAdjustment": -1},
        {"MetricIntervalLowerBound": 0.3, "ScalingAdjustment": -2}
      ],
      "Cooldown": 120,
      "MetricAggregationType": "Average"
  }' --query "PolicyARN" --output text)


echo "CloudWatch alarms intializing..."

# High latency scale-out
aws cloudwatch put-metric-alarm \
  --alarm-name HighLatencyScaleOut \
  --alarm-description "Scales out ECS service if Average ALB TargetResponseTime > 0.5s" \
  --metric-name TargetResponseTime \
  --namespace AWS/ApplicationELB \
  --statistic Average \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 0.5 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=LoadBalancer,Value=$ALB_ARN_SUFFIX Name=TargetGroup,Value=targetgroup/$TG_ARN_SUFFIX \
  --alarm-actions "$SCALE_OUT_POLICY_ARN" \
  --unit Seconds 

# Low latency scale-in
aws cloudwatch put-metric-alarm \
  --alarm-name LowLatencyScaleIn \
  --alarm-description "Scales in ECS service if Average ALB TargetResponseTime < 0.3s" \
  --metric-name TargetResponseTime \
  --namespace AWS/ApplicationELB \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 0.3 \
  --comparison-operator LessThanThreshold \
  --dimensions Name=LoadBalancer,Value=$ALB_ARN_SUFFIX Name=TargetGroup,Value=targetgroup/$TG_ARN_SUFFIX \
  --alarm-actions "$SCALE_IN_POLICY_ARN" \
  --unit Seconds 

# Fetch alarm ARNs for dashboard widgets
HIGH_ALARM_ARN=$(aws cloudwatch describe-alarms \
  --alarm-names HighLatencyScaleOut \
  --query "MetricAlarms[0].AlarmArn" \
  --output text)

LOW_ALARM_ARN=$(aws cloudwatch describe-alarms \
  --alarm-names LowLatencyScaleIn \
  --query "MetricAlarms[0].AlarmArn" \
  --output text)

# Get ARNs for all CloudWatch metric alarms in this region
ALL_ALARM_ARNS=$(aws cloudwatch describe-alarms \
  --query "MetricAlarms[].AlarmArn" \
  --output json)

# Update metrics dimensions and add All Alarms widget
ALB_DIM="$ALB_ARN_SUFFIX"
TG_DIM="targetgroup/$TG_ARN_SUFFIX"

jq --arg alb "$ALB_DIM" \
   --arg tg "$TG_DIM" \
   --argjson alarms "$ALL_ALARM_ARNS" '
  .widgets |= (
    map(
      if (.properties.metrics? // empty) | type == "array" then
        .properties.metrics |= map(
          if type == "array" then
            reduce range(0; length) as $i
              (.;
                if .[$i] == "LoadBalancer" and ($i + 1) < length then
                  .[$i+1] = $alb
                elif .[$i] == "TargetGroup" and ($i + 1) < length then
                  .[$i+1] = $tg
                else
                  .
                end
              )
          else
            .
          end
        )
      else
        .
      end
    )
    | map(
        if (.properties.title // "") == "All Alarms" then
          empty
        else
          .
        end
      )
    + [
        {
          "type": "alarm",
          "x": 0,
          "y": 9,
          "width": 12,
          "height": 3,
          "properties": {
            "title": "All Alarms",
            "alarms": $alarms
          }
        }
      ]
  )
' dashboard.json > dashboard_updated.json


# Push updated dashboard
echo "Updating CloudWatch dashboard..."
aws cloudwatch put-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --dashboard-body file://dashboard_updated.json

echo "Dashboard successfully updated to use the active ALB and TG."

## ===== RUN THE SERVICE =====
# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names $ALB_NAME \
  --query "LoadBalancers[0].DNSName" \
  --output text)

echo ""
echo "✅ Service is running!"
echo "🌍 Public IP: http://$ALB_DNS:$CONTAINER_PORT"
echo "💡 Test it with:"
echo "   curl -X POST http://$ALB_DNS:$CONTAINER_PORT/predict_json -H 'Content-Type: application/json' -d '{\"key\":\"value\"}'"
echo ""
read -p "Press ENTER when done testing to clean everything up... "

# ===== CLEANUP =====
echo "🧹 Cleaning up resources..."

# ------------------------
# Stop all ECS tasks
#------------------------

# Delete ECS service
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force > /dev/null
echo "✅ ECS service deleted"

TASK_ARNS=$(aws ecs list-tasks --cluster $CLUSTER_NAME --query "taskArns" --output text)

if [ -n "$TASK_ARNS" ]; then
  for TASK_ARN in $TASK_ARNS; do
    aws ecs stop-task --cluster $CLUSTER_NAME --task $TASK_ARN > /dev/null
    echo "🛑 Stopped task: $TASK_ARN"
  done
fi

echo "✅ Tasks stopped"


# Delete ECS cluster
aws ecs delete-cluster --cluster $CLUSTER_NAME > /dev/null
echo "✅ ECS cluster deleted"

# Delete load balancer, listener & target group
aws elbv2 delete-listener --listener-arn "$LISTENER_ARN" > /dev/null
echo "✅ Listener deleted"

aws elbv2 delete-target-group --target-group-arn "$TG_ARN" > /dev/null
echo "✅ Target Group deleted"

aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" > /dev/null
echo "✅ Load Balancer deleted"

# ------------------------
# Delete IAM Role & Policy
# ------------------------
# Detach policy if exists
POLICY_ARN=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[0].PolicyArn" --output text)
if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
    aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
    echo "✅ IAM policy detached"
fi

# Delete role
aws iam delete-role --role-name $ROLE_NAME
echo "✅ IAM role deleted"


# ------------------------
# Delete VPC network resources
# ------------------------
while aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$SUBNET_ID" --query "NetworkInterfaces" --output text | grep -q .; do
    echo "⏳ Waiting for network interfaces to detach from $SUBNET_ID..."
    sleep 10
done

# Delete subnet if you created on
aws ec2 delete-subnet --subnet-id $SUBNET_ID > /dev/null
echo "✅ Subnet 1 deleted"

while aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$SUBNET_ID2" --query "NetworkInterfaces" --output text | grep -q .; do
    echo "⏳ Waiting for network interfaces to detach from $SUBNET_ID2..."
    sleep 10
done

# Delete second subnet if you created one
aws ec2 delete-subnet --subnet-id $SUBNET_ID2 > /dev/null
echo "✅ Subnet 2 deleted"

# Delete Internet Gateway if you created one
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
echo "✅ Internet Gateway deleted"

# Delete Route Table
aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID
echo "✅ Route Table deleted"

# ------------------------
# Delete Security Group
# ------------------------
aws ec2 delete-security-group --group-id $SG_ID > /dev/null
echo "✅ Security group deleted"

# ------------------------
# Delete CloudWatch alarms
# ------------------------
aws cloudwatch delete-alarms \
  --alarm-names "HighLatencyScaleOut" "LowLatencyScaleIn" > /dev/null
echo "✅ CloudWatch alarms deleted"
# ------------------------
# Delete temporary files
# ------------------------
rm -f trust-policy.json task-def.json
echo "✅ Temporary files cleaned up"

echo "✅ Cleanup complete. All resources deleted."
