# nopCommerce Deployment Guide — New AWS Account

A step-by-step guide to deploy the nopCommerce application on a fresh AWS account using the infrastructure and scripts already built in this repository.

---

## Prerequisites

- ✅ Your supervisor's IAM Access Key ID and Secret Access Key (with Admin access)
- ✅ AWS CLI installed on your Windows machine ([Download](https://aws.amazon.com/cli/))
- ✅ This nopCommerce repository cloned locally

---

## Phase 1: Configure AWS CLI with the New Account

Open **PowerShell** and run:

```powershell
aws configure
```

Enter the credentials your supervisor gave you:

```
AWS Access Key ID:     AKIA...............
AWS Secret Access Key: wJal...............
Default region name:   us-east-1
Default output format: json
```

Verify it works:

```powershell
aws sts get-caller-identity
```

You should see the new account ID and IAM user name. If you see your old account, run `aws configure` again.

---

## Phase 2: Create an SSH Key Pair

This key allows you to SSH into the new EC2 instance.

```powershell
aws ec2 create-key-pair `
  --key-name nopcommerce-key `
  --query "KeyMaterial" `
  --output text `
  --region us-east-1 > "$HOME\Downloads\nopcommerce-key.pem"
```

> [!CAUTION]
> **Save this `.pem` file securely!** AWS will never let you download it again. If you lose it, you lose SSH access to the server.

---

## Phase 3: Deploy the CloudFormation Stack

This single command creates the entire AWS infrastructure (VPC, EC2, Security Groups, Elastic IP, CloudWatch Alarms):

```powershell
aws cloudformation create-stack `
  --stack-name nopcommerce-prod `
  --template-body file://infrastructure-cost-optimized.yml `
  --parameters `
    ParameterKey=KeyPairName,ParameterValue=nopcommerce-key `
    ParameterKey=AlertEmail,ParameterValue="fredrickamoako@gmail.com" `
  --capabilities CAPABILITY_IAM `
  --region us-east-1
```

> Replace `your.email@example.com` with your real email.

**Wait for it to finish** (takes about 3-5 minutes):

```powershell
aws cloudformation wait stack-create-complete --stack-name nopcommerce-prod --region us-east-1
Write-Host "Stack created successfully!"
```

**Get your new server's Elastic IP:**

```powershell
aws cloudformation describe-stacks `
  --stack-name nopcommerce-prod `
  --query "Stacks[0].Outputs" `
  --output table `
  --region us-east-1
```

Write down the `ElasticIP` value from the output. This is your new server's permanent public IP address.

---

## Phase 4: Confirm Monitoring Email

> [!IMPORTANT]
> If you provided an `AlertEmail`, check your inbox for an email from **"AWS Notifications"** and click **"Confirm subscription"**. Without this, you won't receive CPU/health alerts.

---

## Phase 5: Wait for EC2 UserData to Finish

The CloudFormation template installs Docker, Nginx, and other dependencies automatically via UserData. This takes about **3-5 minutes** after the stack is created.

**Test SSH access:**

```powershell
ssh -i "$HOME\Downloads\nopcommerce-key.pem" ubuntu@54.90.93.63
```

> Replace `<ELASTIC_IP>` with the IP from Phase 4.

If SSH times out, wait another minute. The instance is still booting.

**Verify Docker is installed:**

```bash
docker --version
nginx -v
```

If both commands return version numbers, you're ready to proceed.

---

## Phase 6: Upload Code and Deploy

### 6a. Upload your project files to the server

**Open a NEW PowerShell or Git Bash tab on your local machine** (not the SSH tab):

```powershell
cd d:\Documents\Work_Extra\nopCommerce

rsync -avz -e "ssh -i '$HOME\Downloads\nopcommerce-key.pem'" `
  --exclude '.git' --exclude 'bin' --exclude 'obj' --exclude '.vs' `
  ./src ./Dockerfile.prod ./docker-compose.prod.yml ./.env.example ./deploy `
  ubuntu@54.90.93.63:/opt/nopcommerce/
```

> _Note: By using `rsync -avz`, files are compressed during transfer and only changes are sent, making it vastly faster than `scp`._

### 6b. Configure environment variables

**Go back to your SSH tab** on the server:

```bash
cd /opt/nopcommerce

# Create .env from the template
cp .env.example .env
nano .env
```

Set these values inside `.env`:

```env
ASPNETCORE_ENVIRONMENT=Production
POSTGRES_USER=nopcommerce
POSTGRES_PASSWORD=YourStrongPasswordHere!
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### 6c. Run the initial server setup

```bash
chmod +x deploy/*.sh
./deploy/setup.sh
```

This configures Nginx with a self-signed SSL certificate and sets up the reverse proxy.

### 6d. Build and start the application

```bash
./deploy/deploy.sh
```

This builds the Docker image, starts the PostgreSQL and nopCommerce containers, and waits for them to become healthy.

### 6e. Enable the `citext` PostgreSQL extension

nopCommerce requires this extension for case-insensitive text fields:

```bash
docker exec nopcommerce_db psql -U nopcommerce -d nopcommerce -c 'CREATE EXTENSION IF NOT EXISTS citext;'
```

---

## Phase 7: Complete the nopCommerce Installation Wizard

1. Open your browser and go to: `https://<ELASTIC_IP>`
2. You'll see a certificate warning — click **"Advanced"** → **"Proceed"** (this is expected with a self-signed cert)
3. The nopCommerce Installation Wizard will appear. Fill it in:

| Field                  | Value                                      |
| ---------------------- | ------------------------------------------ |
| **Admin Email**        | `admin@yourstore.com` (or your real email) |
| **Admin Password**     | Choose a strong password                   |
| **Database**           | `PostgreSQL`                               |
| **Server Name**        | `nopcommerce_db`                           |
| **Database Name**      | `nopcommerce`                              |
| **Username**           | `nopcommerce`                              |
| **Password**           | The `POSTGRES_PASSWORD` you set in `.env`  |
| **Create sample data** | ✅ Check this for a demo store             |

4. Click **Install** and wait 1-2 minutes

---

## Phase 8: Post-Deployment Setup

### 8a. Set up automated backups

```bash
# Test the backup script
./deploy/backup.sh

# Schedule it to run daily at 2 AM
(crontab -l 2>/dev/null; echo '0 2 * * * /opt/nopcommerce/deploy/backup.sh > /dev/null 2>&1') | crontab -
```

### 8b. Set up health monitoring

```bash
# Test the monitor script
./deploy/monitor.sh

# Schedule it to run every 5 minutes
(crontab -l 2>/dev/null; echo '*/5 * * * * /opt/nopcommerce/deploy/monitor.sh > /dev/null 2>&1') | crontab -
```

### 8c. (Optional) Set up real SSL with a domain

If you have a domain name pointed to the Elastic IP:

```bash
./deploy/setup-ssl.sh
```

### 8d. (Optional) Enable T3 Unlimited Mode

Prevents CPU throttling during traffic spikes:

```powershell
# Run this on your LOCAL PowerShell (not SSH)
$InstanceId = "i-036e8ee82ece726dd" 
aws ec2 modify-instance-credit-specification `
  --instance-credit-specification "InstanceId=$InstanceId,CpuCredits=unlimited" `
  --region us-east-1
```

### 8e. (Optional) Set up GitHub Actions CI/CD

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions**, and add:

| Secret Name   | Value                                    |
| ------------- | ---------------------------------------- |
| `EC2_HOST`    | Your new Elastic IP                      |
| `EC2_SSH_KEY` | Entire contents of `nopcommerce-key.pem` |

Now every push to `main` will automatically deploy to the new server.

---

## Quick Reference

| Item              | Value                                                                                                                      |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **SSH Command**   | `ssh -i "nopcommerce-key.pem" ubuntu@<ELASTIC_IP>`                                                                         |
| **Project Dir**   | `/opt/nopcommerce`                                                                                                         |
| **View App Logs** | `docker logs nopcommerce_app`                                                                                              |
| **View DB Logs**  | `docker logs nopcommerce_db`                                                                                               |
| **Restart App**   | `docker restart nopcommerce_app`                                                                                           |
| **Full Restart**  | `cd /opt/nopcommerce && docker compose -f docker-compose.prod.yml down && docker compose -f docker-compose.prod.yml up -d` |
| **Monitor Logs**  | `tail -f /var/log/nopcommerce-monitor.log`                                                                                 |
| **Check Memory**  | `docker stats --no-stream`                                                                                                 |
| **Backup Now**    | `/opt/nopcommerce/deploy/backup.sh`                                                                                        |

---

## Troubleshooting

| Problem                                   | Solution                                                                                                                                                                                                                                          |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SSH times out                             | Check Security Group allows your IP on port 22. Your IP may have changed.                                                                                                                                                                         |
| Site not loading                          | Run `docker compose -f docker-compose.prod.yml ps` to check container status                                                                                                                                                                      |
| `$'\r': command not found`                | Your files have Windows line endings instead of Unix line endings. Run `sed -i 's/\r$//' .env deploy/*.sh` on the server to fix it.                                                                                                               |
| `citext` error                            | Run: `docker exec nopcommerce_db psql -U nopcommerce -d nopcommerce -c 'CREATE EXTENSION IF NOT EXISTS citext;'` then restart the app                                                                                                             |
| FluentMigrator error after failed install | Reset DB: `docker exec nopcommerce_db psql -U nopcommerce -d nopcommerce -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO nopcommerce; CREATE EXTENSION IF NOT EXISTS citext;'` then restart the app and retry |
| Images broken (mixed content)             | Already fixed in `deploy/setup.sh` via `sub_filter` — just re-run `./deploy/setup.sh`                                                                                                                                                             |
| Server frozen / no SSH                    | Reboot from AWS Console: EC2 → Instances → Select → Instance State → Reboot                                                                                                                                                                       |
