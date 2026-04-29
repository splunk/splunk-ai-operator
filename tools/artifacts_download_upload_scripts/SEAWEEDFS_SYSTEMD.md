# SeaweedFS as a systemd service

Run SeaweedFS as a systemd service so it **restarts on failure** and **starts on boot**.

## Prerequisites

- **weed** binary at `/usr/local/bin/weed`. If missing, run the upload script once from the artifacts directory (it installs weed), or [download a release](https://github.com/seaweedfs/seaweedfs/releases) and copy `weed` to `/usr/local/bin/`.
- **Root/sudo** on the host to install the service.

## Quick install (EC2 or single host)

On the host where SeaweedFS should run:

```bash
cd /path/to/splunk-ai-operator/tools/artifacts_download_upload_scripts
sudo ./install_seaweedfs_systemd.sh
```

This copies `seaweedfs.service` to `/etc/systemd/system/`, enables and starts the service.

## Manual install

1. Copy the unit file:
   ```bash
   sudo cp tools/artifacts_download_upload_scripts/seaweedfs.service /etc/systemd/system/
   sudo systemctl daemon-reload
   ```

2. Optionally override credentials or data dir via a drop-in or env file:
   ```bash
   sudo mkdir -p /etc/systemd/system/seaweedfs.service.d
   echo -e '[Service]\nEnvironment="AWS_ACCESS_KEY_ID=mykey"\nEnvironment="AWS_SECRET_ACCESS_KEY=mysecret"' | sudo tee /etc/systemd/system/seaweedfs.service.d/override.conf
   sudo systemctl daemon-reload
   ```

3. Enable and start:
   ```bash
   sudo systemctl enable seaweedfs
   sudo systemctl start seaweedfs
   ```

## Service details

- **User:** `ec2-user` (change in the unit if needed).
- **Data dir:** `/home/ec2-user/data` (hardcoded in `ExecStart`; override via a systemd drop-in that replaces `ExecStart` if needed).
- **Volume max:** `100` in `ExecStart` (override via drop-in if needed).
- **S3 credentials:** `minioadmin` / `minioadmin` by default; override with `Environment=` or `EnvironmentFile=-/etc/default/seaweedfs` in a drop-in.
- **Restart:** `on-failure` with 5s delay.
- **Logs:** `journalctl -u seaweedfs -f`

## Useful commands

| Command | Description |
|--------|-------------|
| `sudo systemctl status seaweedfs` | Show status |
| `journalctl -u seaweedfs -f` | Follow logs |
| `sudo systemctl restart seaweedfs` | Restart |
| `sudo systemctl stop seaweedfs` | Stop |
| `sudo systemctl disable seaweedfs` | Disable start on boot |

## After install

- S3 endpoint: **http://127.0.0.1:8333** (or the host’s IP if accessing remotely).
- Use the same credentials in the upload script or set `OBJECT_STORE_ACCESS_KEY` / `OBJECT_STORE_SECRET_KEY` to match the service.

## Troubleshooting: "0 node candidates" / "Not enough data nodes found"

When the Master has no writable volume servers, uploads fail with those errors. Common causes and fixes:

| Cause | Fix |
|-------|-----|
| **1. Max volumes reached** | Volume server default `-max` is often 7–8. The unit sets `SEAWEEDFS_VOLUME_MAX=100`. To increase: add `Environment="SEAWEEDFS_VOLUME_MAX=200"` in a drop-in and restart. |
| **2. Disk space** | At ~95% usage the volume server reports read-only. Check `df -h` on the host; free space or add storage. |
| **3. Heartbeat / gRPC timeouts** | Under heavy load the volume server may miss heartbeats and be marked dead. Check `journalctl -u seaweedfs` for "heartbeat" or "connection refused" around the failure time. |
| **4. OOM** | On small instances the process may be killed. Run `dmesg -T | grep -i oom` on the host. |

**When the error is happening, run:**

```bash
# Master's view of nodes (look for empty Nodes or IsReadOnly: true)
curl -s http://localhost:9333/cluster/status | jq

# Volume server status (check if Max and Count are equal = full)
curl -s http://127.0.0.1:8080/status | jq
```

If `Max == Count` on the volume server, increase `SEAWEEDFS_VOLUME_MAX` and restart the service.

### "Permission denied" when starting the service (status=203/EXEC)

The service runs as `ec2-user`. Common causes:

1. **File permissions** – Ensure the binary is executable by all:
   ```bash
   sudo chmod 755 /usr/local/bin/weed
   ```

2. **SELinux (Enforcing)** – On RHEL/Amazon Linux, SELinux can block execution. Fix by labeling the binary:
   ```bash
   sudo chcon -t bin_t /usr/local/bin/weed
   sudo systemctl restart seaweedfs
   ```
   To confirm SELinux is the cause: `sudo setenforce 0`, restart the service; if it then runs, re-enable with `sudo setenforce 1` and apply the `chcon` above.

The install script runs `chmod 755` and, when SELinux is Enforcing, `chcon -t bin_t` automatically.

### Connect timeout from EKS / Ray pods (Connection to &lt;host&gt; timed out)

Ray workers (and other pods) in the cluster need to reach the SeaweedFS S3 endpoint to download model artifacts. If you see:

- `Connect timeout on endpoint URL: "http://<ip>:8333/..."`
- `Connection to <ip> timed out. (connect timeout=60)"`

then **pods cannot reach the SeaweedFS host** on port 8333.

**Fix:**

1. **Security group on the SeaweedFS EC2**  
   Allow **inbound TCP port 8333** from the EKS cluster:
   - **Option A:** From the **EKS worker node security group** (so any pod on those nodes can reach SeaweedFS).
   - **Option B:** From the **VPC CIDR** (e.g. `10.0.0.0/16` or `192.168.0.0/16`) so all pods in the VPC can reach SeaweedFS.

   In AWS Console: EC2 → Security Groups → select the security group attached to the SeaweedFS instance → Edit inbound rules → Add rule: Type = Custom TCP, Port = 8333, Source = node SG or VPC CIDR.

2. **Prefer private IP when in the same VPC**  
   If SeaweedFS and EKS are in the same VPC, set `storage.objectStore.endpoint` in `cluster-config.yaml` to the **private IP** and port (e.g. `http://172.31.23.74:8333`). Then:
   - Traffic stays inside the VPC (no internet path).
   - The security group still must allow 8333 from the node SG or VPC CIDR as above.

3. **Verify from a pod** (optional):
   ```bash
   kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- curl -s -o /dev/null -w "%{http_code}" http://<seaweedfs-ip>:8333
   ```
   Use the same IP (public or private) and port as in your config. A 200/403/400 means the pod can reach SeaweedFS.
