# nopCommerce AWS Deployment — Step-by-Step Guide

> **What this deploys:** nopCommerce on a single AWS EC2 instance with Docker, Nginx reverse proxy, SSL, and automated backups.
>
> **Monthly cost:** ~$18–22/month (t3.small + 25GB gp3 + Elastic IP).

---

## Prerequisites

Before starting, ensure you have:

- [x] **AWS Account** with billing enabled
- [x] **AWS CLI** installed (`aws --version` should return 2.x)
- [x] **Key Pair** — your `.pem` file for SSH access (e.g., `Jayks.pem`)
- [ ] **AWS Credentials configured** (Step 1 below)
- [ ] **Domain name** (optional — can use the Elastic IP directly)

> **Note:** Steps 1–10 are the complete deployment. You do NOT need GitHub access or CI/CD to host the site.

---

## Step 1: Configure AWS CLI

Run this in your terminal. Enter your Access Key ID and Secret Access Key when prompted:

```bash
aws configure
```

You'll be asked for:
| Prompt | What to enter |
|--------|---------------|
| AWS Access Key ID | Your IAM access key |
| AWS Secret Access Key | Your IAM secret key |
| Default region name | `us-east-1` (or your preferred region) |
| Default output format | `json` |

> **Don't have an Access Key?** Go to [AWS IAM Console](https://console.aws.amazon.com/iam/) → Users → Your user → Security credentials → Create access key.

### Verify it works:

```bash
aws sts get-caller-identity
```

You should see your AWS account number and user ARN.

---

## Step 2: Find the Correct AMI for Your Region

The CloudFormation template defaults to a `us-east-1` Ubuntu AMI. If you're deploying to a **different region**, find the correct AMI:

```bash
aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text --region us-east-1
```

Note the AMI ID for the `--parameters` in Step 3.

---

## Step 3: Deploy the Infrastructure

This creates your VPC, EC2 instance, security group, and Elastic IP:

```bash
aws cloudformation create-stack ^
  --stack-name nopcommerce-cost-optimized ^
  --template-body file://infrastructure-cost-optimized.yml ^
  --parameters ^
    ParameterKey=InstanceType,ParameterValue=t3.small ^
    ParameterKey=KeyPairName,ParameterValue=Jayks ^
    ParameterKey=YourIpAddress,ParameterValue=154.161.53.119/32 ^
  --capabilities CAPABILITY_IAM ^
  --region us-east-1
```

> **Replace `YOUR_IP`** with your public IP. Find it by visiting [checkip.amazonaws.com](https://checkip.amazonaws.com) in your browser.

### Wait for the stack to complete (~3-5 minutes):

```bash
aws cloudformation wait stack-create-complete --stack-name nopcommerce-cost-optimized --region us-east-1
```

### Get your Elastic IP:

```bash
aws cloudformation describe-stacks `
  --stack-name nopcommerce-cost-optimized `
  --query "Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue" `
  --output text --region us-east-1
```

**Save this IP** — you'll use it for everything below.

---

## Step 4: SSH Into Your Server

```bash
ssh -i "C:\Users\Administrator\Downloads\Jayks.pem" ubuntu@100.51.132.148
```

> **Permission error?** On the first run, you may need to fix key permissions. In PowerShell (run as Administrator):
>
> ```powershell
> icacls "C:\Users\Administrator\Downloads\Jayks.pem" /inheritance:r
> icacls "C:\Users\Administrator\Downloads\Jayks.pem" /grant:r "%USERNAME%:R"
> ```

Once connected, verify the setup completed:

```bash
# Check Docker is installed
docker --version

# Check Nginx is running
sudo systemctl status nginx

# Check swap is active
free -h
```

If Docker isn't installed yet, the UserData script may still be running. Check with:

```bash
tail -f /var/log/user-data.log
```

---

## Step 5: Upload Your Project Files

Open a **new local terminal** (not the SSH session) and upload the project:

```bash
rsync -avz --progress `
  --exclude ".git" `
  --exclude ".vs" `
  --exclude "bin" `
  --exclude "obj" `
  --exclude "node_modules" `
  --exclude "backups" `
  -e "ssh -i C:\Users\Administrator\Downloads\Jayks.pem" `
  . ubuntu@100.51.132.148:/opt/nopcommerce/
```

> **On Windows without rsync?** Use `scp` instead:
>
> ```bash
> scp -i "C:\Users\Administrator\Downloads\Jayks.pem" -r . ubuntu@100.51.132.148:/opt/nopcommerce/
> ```

---

## Step 6: Run Initial Setup

SSH back into the server and run the setup script:

```bash
ssh -i "C:\Users\Administrator\Downloads\Jayks.pem" ubuntu@100.51.132.148
cd /opt/nopcommerce

# Make scripts executable
chmod +x deploy/setup.sh deploy/deploy.sh deploy/backup.sh deploy/setup-ssl.sh

# Create your .env file from the template
cp .env.example .env

# IMPORTANT: Set a strong database password!
nano .env
```

**In the `.env` file, change `DB_PASSWORD` to a strong password.** Example:

```
DB_PASSWORD=MyStr0ng!Passw0rd#2026
```

Save and close (`Ctrl+X` → `Y` → `Enter`), then run setup:

```bash
./deploy/setup.sh
```

This will:

- Generate a self-signed SSL certificate
- Configure Nginx as a reverse proxy with security headers
- Test the Nginx configuration

---

## Step 7: Deploy the Application

```bash
./deploy/deploy.sh
```

This will:

- Validate your `.env` password is not the default
- Build the Docker images from `Dockerfile.prod`
- Start the database and application containers
- Wait for both to become healthy
- Print the install wizard connection string

**First build takes 5-10 minutes** (downloading .NET SDK, compiling, pulling SQL Server image).

---

## Step 8: Complete the nopCommerce Install Wizard

1. Open `https://<YOUR-ELASTIC-IP>` in your browser
2. You'll see a certificate warning (expected with self-signed cert) — click **Advanced → Proceed**
3. The nopCommerce installation page appears
4. Fill in:
   - **Store name:** Your store name
   - **Admin email:** Your admin email
   - **Admin password:** Choose a strong password
   - **Database:** Select **Microsoft SQL Server**
   - **Connection string:** _(the deploy script printed this — copy it)_:
     ```
     Server=nopcommerce_db;Database=nopCommerce;User Id=sa;Password=YOUR_DB_PASSWORD;TrustServerCertificate=True;Encrypt=False
     ```
   - **Create sample data:** Check if you want demo products
5. Click **Install** — this takes 2-5 minutes
6. You'll be redirected to your store homepage

> **Important:** Your database config is stored in a Docker volume. It persists even when you redeploy.

---

## Step 9: Set Up Real SSL (Optional but Recommended)

If you have a domain name pointing to your Elastic IP:

```bash
./deploy/setup-ssl.sh
```

This will:

- Ask for your domain name
- Verify DNS resolution
- Obtain a Let's Encrypt SSL certificate
- Update Nginx with the real certificate
- Set up auto-renewal via cron

---

## Step 10: Set Up Automated Backups

Add a cron job to run daily backups at 2 AM:

```bash
crontab -e
```

Add this line:

```
0 2 * * * /opt/nopcommerce/deploy/backup.sh >> /var/log/nopcommerce-backup.log 2>&1
```

Test the backup manually:

```bash
./deploy/backup.sh
```

---

## Step 11: Set Up GitHub Actions Deployment (OPTIONAL — Repo Owners Only)

> **Skip this step** if you don't own the repository or don't need automated deployment.
> Steps 1–10 above are the complete manual deployment. This step only adds automation
> so that pushing to `main` auto-deploys — it requires repository admin access.

### 11.1 What Are GitHub Secrets?

GitHub Secrets are encrypted variables stored in your repository settings. They let your CI/CD pipeline access sensitive data (like SSH keys) without exposing them in code.

### 11.2 How to Add GitHub Secrets

1. Go to your GitHub repository: `https://github.com/YOUR-USERNAME/nopCommerce`
2. Click **Settings** (top menu bar)
3. In the left sidebar, click **Secrets and variables** → **Actions**
4. Click **New repository secret**
5. Add these two secrets:

| Secret Name   | Value                                                                                |
| ------------- | ------------------------------------------------------------------------------------ |
| `EC2_SSH_KEY` | The **entire contents** of your `Jayks.pem` file (open in Notepad, Select All, Copy) |
| `EC2_HOST`    | Your Elastic IP address (e.g., `54.123.45.67`)                                       |

### 11.3 Verify

After pushing to `main`, go to **Actions** tab in GitHub. You should see the "Deploy to EC2" workflow running.

---

## File Reference

All deployment files are already in your repository:

| File                                | Purpose                                                |
| ----------------------------------- | ------------------------------------------------------ |
| `infrastructure-cost-optimized.yml` | CloudFormation template (VPC, EC2, EIP, security)      |
| `docker-compose.prod.yml`           | Production Docker Compose                              |
| `Dockerfile.prod`                   | Multi-stage build with health endpoint + non-root user |
| `.env.example`                      | Environment variable template                          |
| `deploy/setup.sh`                   | One-time Nginx + SSL setup                             |
| `deploy/deploy.sh`                  | Build & deploy containers                              |
| `deploy/backup.sh`                  | Database + volume backup                               |
| `deploy/setup-ssl.sh`               | Let's Encrypt SSL setup                                |
| `.github/workflows/deploy-ec2.yml`  | CI/CD pipeline                                         |
| `src/.../HealthCheckStartup.cs`     | `/health` endpoint for Docker healthchecks             |

---

## Cost Breakdown

| Component     | Specs                       | Monthly Cost      |
| ------------- | --------------------------- | ----------------- |
| EC2 Instance  | t3.small (2 vCPU, 2 GB RAM) | ~$15.18           |
| EBS Storage   | 25 GB gp3, encrypted        | ~$2.00            |
| Elastic IP    | 1 static IP (attached)      | ~$3.60            |
| Data Transfer | First 100 GB free           | $0.00             |
| **Total**     |                             | **~$20.78/month** |

> **Save more:** Use a 1-year Reserved Instance to cut the EC2 cost by ~40%.

---

## Troubleshooting

### Container won't start

```bash
# Check container logs
docker compose -f docker-compose.prod.yml logs nopcommerce
docker compose -f docker-compose.prod.yml logs db

# Check container status
docker compose -f docker-compose.prod.yml ps
```

### Site shows "502 Bad Gateway"

```bash
# Check if nopCommerce container is running
docker ps

# Check Nginx config
sudo nginx -t

# Check Nginx logs
sudo tail -20 /var/log/nginx/error.log
```

### Out of memory

```bash
# Check memory usage
free -h
docker stats --no-stream

# Add more swap if needed
sudo fallocate -l 2G /swapfile2
sudo chmod 600 /swapfile2
sudo mkswap /swapfile2
sudo swapon /swapfile2
echo '/swapfile2 none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Database connection failed in install wizard

- Verify the password in your `.env` file matches exactly what you type in the wizard
- The server name must be `nopcommerce_db` (the Docker service name, not localhost)
- Check if the DB is healthy: `docker inspect --format='{{.State.Health.Status}}' nopcommerce_db`
