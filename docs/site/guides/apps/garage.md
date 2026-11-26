---
title: Object storage (Garage)
description: Run Garage for S3 storage, give it its own disk, open the web UI, and give apps buckets.
sidebar:
  order: 4
---

[Garage](https://garagehq.deuxfleurs.fr/) is the platform's S3-compatible
object storage. It runs as one node, so each object is stored once. The
nightly `quarantine backup` is what protects the data.

| | |
|---|---|
| S3 endpoint, inside the platform | `http://garage:3900` |
| S3 endpoint, from outside | `https://s3.${DOMAIN}` |
| Region | `garage` |
| Addressing | Path-style only (`forcePathStyle: true`) |
| Web UI | `https://storage.${DOMAIN}` (the `garage-ui` app) |

## 1. Give Garage its own disk

Object data lives on a separate Incus disk, mounted in the VM at
`/srv/quarantine/garage-data`. A full disk then stops new uploads, but
can't fill the VM's root disk and take every other app down with it.
Garage won't start until that directory exists.

Today: **10 GiB on dev, 100 GiB on prod.**

On the host (`homelab`), create the disk and attach it to the VM. Swap in
`prod` and your size as needed:

```bash
sudo incus storage volume create default dev-garage size=10GiB --type=block
```

```bash
sudo incus storage volume attach default dev-garage dev
```

In the VM, find the new disk (the one with no partitions and the right size),
format it and mount it by UUID:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

```bash
sudo mkfs.ext4 -L garage-data /dev/sdX
```

```bash
sudo mkdir -p /srv/quarantine/garage-data && echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX) /srv/quarantine/garage-data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab && sudo mount -a
```

### Making it bigger later

Grow the volume on the host, then the filesystem in the VM. Both work while
everything runs:

```bash
sudo incus storage volume set default prod-garage size=200GiB
```

```bash
sudo resize2fs /dev/sdX
```

Check with `df -h /srv/quarantine/garage-data`.

## 2. Turn it on

```bash
quarantine app add garage
```

```bash
quarantine app add garage-ui
```

Then `quarantine start`. The first start writes new secrets for both apps
into `secrets.sops.yaml` on the host. Commit that file through a PR, or the
next deploy refuses the dirty checkout.

## 3. Open the web UI

Only people holding a role on the `garage-ui` Zitadel project can sign in,
and everyone who can sign in is a full admin:

```bash
quarantine user grant someone@example.com garage-ui garage-ui:admin
```

The UI can create buckets and keys, but keys made there are not saved in
`secrets.sops.yaml`. Give apps their buckets with `needs_bucket` instead.

## 4. Give an app a bucket

Set `needs_bucket: true` on the app's `catalog.yaml` entry. On the next
`quarantine start`, the app gets a bucket named after it and a key that only
works on that bucket, as `S3_BUCKET_<APP>`, `S3_ACCESS_KEY_ID_<APP>` and
`S3_SECRET_ACCESS_KEY_<APP>`. See [Add an app](/platform/guides/apps/add-an-app/).

## Command line

There is a `garage` CLI inside the container:

```bash
docker exec quarantine-garage /garage bucket list
```

```bash
docker exec quarantine-garage /garage status
```
