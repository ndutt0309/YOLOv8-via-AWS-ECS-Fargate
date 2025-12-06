## Run YOLOv8 using AWS ECS + Fargate Pipeline

This project runs the object detection model YOLOv8 on an AWS ECS Fargate Pipeline levaraging the auto scaling and load balancing capabilities of AWS and comparing it to an AWS EC2 Baseline. The model is run against the COCO 2017 Validation data using a live simulation.

**Files:**
- `run_fargate.sh`: Will create and configure all required resources for AWS CLI. All resources created in the file are deleted at the end.
- `run_fargate_partial.sh`: Will create and configure all required resources for AWS CLI. Only core architecture resources created in the file are deleted at the end.
- `yolo-api_amd64-20251104`: Container image to be uploaded to AWS ECR.
- `dashboard.json`: CloudWatch Dashboard configuration with metrics and alarms. ARNs will be updated appropriately when run_fargate.sh is run.
- `requirements.txt`: Requirements to install for running the live simulation.
- `live_request_sim.py`: Script to submit image requests iteratively in varying loads and frequencies.
- `coco_val_manifest.json`: Contains all requests for the 5,000 images in the COCO 2017 Validation dataset.
- `request_log.ndjson`: Contains the responses after requests are sent, including the class detected in the image (person, dog, plant, etc).


The file `run_fargate.sh` uses AWC CLI to automatically set up all the required resources that allow you to run the image yolo-api_amd64-20251104.tar from your ECR repo (yolo-api), submit the requests, and clean up all the created resources. You can instead `run_fargate_partial.sh` to set up all required resources and only clean up some resources while maintaining the core architecture for a future re-run (retains IAM role, ECS cluster, VPC, subnets, route table, internet gateway, security group, and CloudWatch Alarms).

Note that Steps 1-2 (AWS CLI setup and loading image to ECR) only have to be completed once, after which you can begin running the pipeline at Step 3.

## Step 1 - Set up AWS CLI credentials

If you haven’t used the AWS CLI on this machine yet, do this first:

1. Create an access key for your IAM user (your AWS account):
   - AWS Console → IAM → Users → *your user* → Security credentials → Create access key
   - Choose Command Line Interface (CLI), then copy both:
     - Access key ID
     - Secret access key

2. Configure the AWS CLI in Terminal:
   ```bash
   aws configure
   ```

   Enter:
   ```
   AWS Access Key ID [None]: <YOUR_ACCESS_KEY_ID>
   AWS Secret Access Key [None]: <YOUR_SECRET_ACCESS_KEY>
   Default region name [None]: us-east-1
   Default output format [None]: json
   ```

3. Verify your CLI is connected to your account:
   ```bash
   aws sts get-caller-identity
   ```
   You should see JSON with your Account number and ARN.

Once this is done, you can log in to ECR and push images.

## Step 2 - Load the Image and push to ECR

### Load the Docker image

1. Make sure Docker Desktop is installed and running. 

2. Load the image into Docker:
   ```bash
   docker load -i yolo-api_amd64-20251104.tar
   ```
   You’ll see something like:
   ```
   Loaded image: yolo-api:amd64-20251104
   ```

3. Verify architecture
   ```bash
   docker inspect yolo-api:amd64-20251104 --format '{{.Architecture}}'
   ```
   You should see 'amd64'
   
The image is now available in your local Docker system.

---

### Retag it for your AWS account

1. Replace `<YOUR_ACCOUNT_ID>` with your own AWS account ID.

2. Run the following commands:
   ```bash
   aws ecr create-repository --repository-name "yolo-api" --region "us-east-1" >/dev/null 2>&1 || true

   aws ecr get-login-password --region "us-east-1" \
   | docker login --username AWS --password-stdin "<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com"

   docker tag "yolo-api:amd64-20251104" "<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/yolo-api:amd64-20251104"
   docker push "<YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/yolo-api:amd64-20251104"
   ```

3. You can confirm using the below code.
   ```bash
   docker images | grep yolo-api
   ```
You’ll see something like -

    ```bash
    REPOSITORY        TAG           IMAGE ID       SIZE

    yolo-api     amd64-20251104     abc123...      528MB
    ```

## Step 3 - Run the AWS pipeline

1. Create a small `.env` file with these lines:
   ```
   MODEL_NAME=yolov8n
   CONF_THRESHOLD=0.25
   DOWNLOAD_TIMEOUT_S=8
   MAX_IMAGE_MB=10
   PORT=8080
   ```

2. Run the script:
```bash
   sh run_fargate.sh
```

If everything is set up successfully, you will see something like:

```
🔹 Using account: <YOUR_ACCOUNT_ID> in region: us-east-1
🔹 Image: <YOUR_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/yolo-api:amd64-20251104
🔹 Port: 8080
Using existing ECS cluster: temp-fargate-cluster
✅ Using existing IAM role: ecsTaskExecutionRole
✅ Using default VPC: vpc-...
✅ Created Internet Gateway: igw-...
✅ Using existing Route Table: rtb-...
✅ Created first subnet: subnet-... (us-east-1a) with CIDR .../24
✅ Created second subnet: subnet-... (us-east-1b) with CIDR .../24
✅ Created security group: sg-...
✅ Target group created: arn:aws:elasticloadbalancing:us-east-1:...
✅ ALB created: arn:aws:elasticloadbalancing:us-east-1:...
✅ ALB Listener created: arn:aws:elasticloadbalancing:us-east-1:...
✅ Task definition already exists: ...
✅ ECS service created: ...
⏳ Waiting 5 minutes for ECS tasks to become healthy in the Target Group...
🔄 Still waiting... (attempt 1)
🔄 Still waiting... (attempt 2)
🔄 Still waiting... (attempt 3)
🔄 Still waiting... (attempt 4)
✅ ECS task(s) are healthy!
📈 Configuring auto scaling for ECS service...

✅ Service is running!
🌍 Public IP: temp-fargate-alb-27906923.us-east-1.elb.amazonaws.com:8080
💡 Test it with:
   curl -X POST http://temp-fargate-alb-27906923.us-east-1.elb.amazonaws.com:8080/predict_json -H 'Content-Type: application/json' -d '{"key":"value"}'

Press ENTER when done testing to clean everything up... 
```

The **PUBLIC_IP** may be different with each execution of the script.

In a separate terminal, submit your curl command using the returned **PUBLIC_IP**. Your command for a single image will look like

```bash
curl -s -X POST http://temp-fargate-alb-27906923.us-east-1.elb.amazonaws.com:8080/predict_json \
  -H "Content-Type: application/json" \
  -d '{
        "req_id": "test-1",
        "image_id": 397133,
        "coco_url": "http://images.cocodataset.org/val2017/000000397133.jpg"
      }'
```

You’ll get a JSON response with the detection and timing for the specified image_id.

## Step 4 - Submitting multiple requests simulataneously

1. Navigate to '/live_request'.

2. Install requirements.

 ```bash
   pip install -r requirements.txt
```

3. Create a `.env` file with the following variable

```
API_BASE_URL=http://temp-fargate-alb-27906923.us-east-1.elb.amazonaws.com:8080
```

This is the IP and port returned when you set up the AWS envrionment in Step 3.

### Run the request simulator 

From a separate terminal, you can test the application by sending loads with different latencies and volume (number of image requests up to 5,000). You can also run from multiple terminals in parallel to simulate multiple users.

**Modes**:
- *Quiet*: Randomd elay between requests within 2.0 - 6.0 seconds.
- *Sustained*: Random delay between requests within 0.2 - 0.5 seconds.
- *Burst*: Random delay between requests within 0.02 - 0.12 seconds.

**Example commands:**

```
python3 live_request_sim.py --mode quiet --limit 50 --manifest "coco_val_manifest.json"

# sustained mode
python3 live_request_sim.py --mode sustained --limit 100 --manifest "coco_val_manifest.json"

# burst mode
python3 live_request_sim.py --mode burst --limit 500 --manifest "coco_val_manifest.json"
```

**Output:**
- `request_log.ndjson` will be written containing one JSON object per line with `status`, `latency_ms`, `req_id`, `detections`. etc.
- The simulator logs summary p50/p95/p99 and mean latencies to stdout (or logging) as well.

### CloudWatch Dashboard

When you run the ECS Fargate pipeline, the dashboard is automatically created via the shell script. The ARNs for Target Group and ALB will be automatically udpated with each re-run. Here you can track all the metrics tied to the auto scaling policies and alarms.


## Step 5 - Clean up

Return to the original terminal from where you ran `run_fargate.sh` and hit 'Enter'. This will begin the clean up process and delete all the resources that were created in that script. You will see something as follow:

```
🧹 Cleaning up resources...
✅ ECS service deleted
✅ Tasks stopped
✅ ECS cluster deleted
✅ Listener deleted
✅ Target Group deleted
✅ Load Balancer deleted
✅ IAM policy detached
✅ IAM role deleted
⏳ Waiting for network interfaces to detach from subnet-...
✅ Subnet 1 deleted
⏳ Waiting for network interfaces to detach from subnet-...
⏳ Waiting for network interfaces to detach from subnet-...
✅ Subnet 2 deleted
✅ Internet Gateway deleted
✅ Route Table deleted
✅ Security group deleted
✅ Temporary files cleaned up
✅ Cleanup complete. All resources deleted.
```

You will have to manually delete your ECR repo.

Verify everything is deleted.