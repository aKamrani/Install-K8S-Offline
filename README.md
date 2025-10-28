<div align="center">
# 🚀 Install K8S Offline
##By Kubespray
</div>

## ✨ What's this?
Offline helper for the [Kubespray offline environment](https://kubespray.io/#/docs/operations/offline-environment) — now powered by a single orchestrator: `offline.sh` 🧰

### It can:

- 📦 Download OS repositories (RPM/DEB)
- 🐳 Pull and save all container images used by Kubespray
- 🐍 Mirror PyPI packages required by Kubespray
- 🎯 Prepare target-node helper scripts (containerd, nginx, registry, etc.)

All artifacts land in `./outputs` 📁

## ✅ Supported OS

- RHEL / AlmaLinux / Rocky Linux: 9
- Ubuntu: 22.04 / 24.04

Note: RHEL8 support was dropped from Kubespray 2.29.0.

## ⚙️ Configure

Edit `config.sh` before running. By default we use `podman`. You can switch to `docker` or `nerdctl` by setting `docker` in `config.sh`.

## 🧪 Quick start

Run the full workflow on a machine with the same OS as your target nodes:

```bash
./offline.sh all
```

This performs, in order:

- `precheck` → env checks
- `prepare-pkgs` → install required system packages (podman, git, python, etc.)
- `prepare-py` → create venv and install Python deps
- `kubespray-fetch` → fetch/extract kubespray and apply patches
- `pypi-mirror` → build PyPI mirror required by kubespray
- `kubespray-files` → download binaries and generate images list, then fetch files
- `images-extra` → pull any images listed in `imagelists/*.txt`
- `repo` → build local RPM/DEB repositories
- `copy-target` → copy target scripts into `outputs/`

## 🔧 Power users: subcommands

```bash
./offline.sh precheck            # quick sanity checks
./offline.sh prepare-pkgs       # system packages
./offline.sh prepare-py         # venv + pip packages
./offline.sh kubespray-fetch    # get kubespray sources
./offline.sh pypi-mirror        # build PyPI mirror
./offline.sh kubespray-files    # files.list + images.list + downloads
./offline.sh images             # download images from images.list
./offline.sh images-extra       # download additional images (imagelists/*.txt)
./offline.sh repo               # build local OS repos (RPM/DEB)
./offline.sh copy-target        # copy target scripts into outputs/
```

## 🧩 Target node helper scripts

After `./offline.sh all`, copy `outputs/` to the node that runs Ansible. Then from `outputs/` run:

- `setup-container.sh` → install containerd from local files and load base images
- `start-nginx.sh` → start nginx serving local repos and PyPI mirror
- `setup-offline.sh` → configure yum/apt to use the local nginx
- `setup-py.sh` → install python3 and venv from local repo
- `start-registry.sh` → start a private registry
- `load-push-all-images.sh` → load and push images to the private registry
- `extract-kubespray.sh` → extract kubespray and apply patches

Ports for nginx and the private registry are configurable in `config.sh` 🔧

## 📚 Kubespray deployment (offline)

1) Create and activate a venv:

```bash
python3.11 -m venv ~/.venv/3.11
source ~/.venv/3.11/bin/activate
python --version
```

2) Extract kubespray and apply patches:

```bash
./extract-kubespray.sh
cd kubespray-{version}
```

3) Install ansible:

```bash
pip install -U pip
pip install -r requirements.txt
```

4) Create `offline.yml`:

Copy [`offline.yml`](./offline.yml) to your `group_vars/all/offline.yml` and edit it (replace `YOUR_HOST` with your registry/nginx host IP).

Notes:

- `runc_donwload_url` must include `runc_version`.
- Since Kubespray 2.23.0, use `containerd_registries_mirrors` instead of `containerd_insecure_registries`.

5) Deploy offline repo configuration to all nodes:

```bash
cp -r ${outputs_dir}/playbook ${kubespray_dir}
cd ${kubespray_dir}
ansible-playbook -i ${your_inventory_file} offline-repo.yml
```

6) Run Kubespray:

```bash
ansible-playbook -i inventory/mycluster/hosts.yaml --become --become-user=root cluster.yml
```

Happy clustering! 🌟
