# Deploying to the Oracle Cloud VM

The whole backend (postgres, nats, mlflow, inference, the 4 domain services,
the gateway, and optionally web-client) runs as one `docker compose` stack --
the same `docker-compose.yml` you already use locally. Production is just
this repo checked out on the VM, with `.env` filled in for real and
`docker compose up -d` running.

## 1. One-time VM setup

SSH into the instance (Oracle gives you the public IP after creation):

```bash
ssh ubuntu@<VM_PUBLIC_IP>   # or opc@ on an Oracle Linux image

# Docker + compose plugin
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

git --version || sudo apt-get install -y git   # (or dnf/yum on Oracle Linux)
```

## 2. Open the firewall -- two layers on Oracle Cloud, both need it

**a) Oracle's Security List / Network Security Group** (console-side, not
the VM's OS): VCN → your subnet → Security Lists → Add Ingress Rule:
- Source CIDR `0.0.0.0/0`, TCP, destination port **8080** (gateway)
- Source CIDR `0.0.0.0/0`, TCP, destination port **4200** (web-client, if
  you're serving it from the VM instead of Vercel)
- Leave everything else closed -- postgres/nats/mlflow/inference/domain
  services are bound to `127.0.0.1` in the compose files, so they're not
  reachable externally even if this rule were wider.

**b) The VM's own OS firewall** (Ubuntu images ship with iptables rules
that block most inbound traffic by default, separately from the above):

```bash
sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 4200 -j ACCEPT
sudo netfilter-persistent save   # persist across reboots, if installed
```

## 3. Get the code onto the VM and configure it

```bash
git clone <this-repo-or-each-of-the-three> ~/amcp
cd ~/amcp
cp .env.example .env
# fill in real SUPABASE_* values (same ones you already have),
# ALLOWED_ORIGINS=<wherever your frontend actually is -- the VM's own IP:4200,
# or your Vercel domain if the frontend is deployed there instead>
```

## 4. Bring it up

```bash
docker compose up -d --build
docker compose ps           # everything should be "healthy" or "running"
curl http://localhost:8080/v1/health
```

From your own machine: `curl http://<VM_PUBLIC_IP>:8080/v1/health` should
now return the same thing.

## 5. Point the frontends at it

Edit `apps/web-client/amcp-web-client/src/app/core/config.prod.ts` (and the
admin-client's) — replace `REPLACE-WITH-VM-IP` with the real IP or a domain
once you've pointed one at it, then `ng build --configuration production`
and deploy that build to Vercel as usual.

## 6. Redeploying after a code change

```bash
cd ~/amcp
git pull
docker compose up -d --build
```

No downtime tooling here yet (no blue/green, no rolling restart) -- this is
a straightforward stop/rebuild/start. Fine for where the project is now;
revisit if uptime during deploys starts to matter.

## What's intentionally NOT exposed publicly

postgres, nats, mlflow, inference, and all 4 domain services are bound to
`127.0.0.1` in the compose files -- only reachable from other containers on
the same docker network, or from the VM itself via SSH tunnel
(`ssh -L 5000:localhost:5000 ubuntu@<VM_IP>` to view the MLflow UI, e.g.).
Only the gateway (8080) is meant to be public. If you add a new service,
default its `ports:` entry to `127.0.0.1:<port>:<port>` unless it genuinely
needs to be internet-facing.
