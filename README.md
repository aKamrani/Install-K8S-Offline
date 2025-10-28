<div align="center">
  <b>🚀 Install K8S Offline</b><br/>
  <b>By Kubespray</b>
</div>

## ✨ What's this?
Offline helper for the [Kubespray offline environment](https://kubespray.io/#/docs/operations/offline-environment) — powered by a single orchestrator: `offline.sh` 🧰

## 🛤️ Two ways to install Kubernetes offline

1) 🧑‍🏭 DIY with this repo: download all required packages, images, and files yourself using `./offline.sh`.
2) 🧳 Use prebuilt Docker images: `akamrani/offline-kubespray:<k8s-version>` (e.g. `akamrani/offline-kubespray:1.32.8`) and extract the prepared files from the image.

The guide for option 2 is below; the DIY workflow (option 1) follows afterward.

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

---

## 🧳 Option 2: Use the prebuilt Docker image

Images are tagged by Kubernetes version, e.g. `akamrani/offline-kubespray:1.32.8`. You can also use a registry mirror if you have one (example below include `akamrani`).

### Step 1: Extract Kubespray Files 📂

Use one of the following commands to extract the installation files from the Docker image:

```bash
# Using specific version (Docker Hub)
cid=$(docker create akamrani/offline-kubespray:1.32.8) && \
  docker cp "$cid:/data/install-k8s-offline" ./install-k8s-offline && \
  docker rm "$cid"

# Or using latest tag (Docker Hub)
cid=$(docker create akamrani/offline-kubespray:latest) && \
  docker cp "$cid:/data/install-k8s-offline" ./install-k8s-offline && \
  docker rm "$cid"
```

This command will:

- 🏗️ Create a container from the image
- 📋 Copy the installation files to your local directory
- 🗑️ Clean up the temporary container

### Step 2: Navigate to the Installation Directory 📁

```bash
cd ./install-k8s-offline
```

### Step 3: Run Setup Scripts 📜

Run the following scripts in order:

```bash
./setup-container.sh      # 🐳 Install containerd from local files; load nginx and registry images
./start-nginx.sh          # 🌐 Start nginx container
./setup-offline.sh        # ⚙️ Configure yum/apt & PyPI to use local nginx
./setup-py.sh             # 🐍 Install python3 and venv from local repo
./start-registry.sh       # 📦 Start docker private registry container
./load-push-all-images.sh # 🚀 Load all images to containerd, tag & push to registry
./extract-kubespray.sh    # 📋 Extract kubespray tarball and apply patches
```

### Configuration 🔧

You can configure the port numbers of nginx and the private registry in the `config.sh` file.

### Step 4: Install Required Packages 📦

Install Python 3, pip, and Ansible:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip
pip install ansible
```

Compatible Ansible Versions ✅

- Ansible: 9.13.0
- Ansible Core: 2.16.14

To check your installed Ansible versions:

```bash
pip show ansible ansible-core
```

Recommended: Use the exact versions mentioned above for best compatibility. 🎯

### Step 5: Extract Kubespray and Apply Patches 🛠️

```bash
./extract-kubespray.sh
cd kubespray-{version}
```

### Step 6: Create and Activate Virtual Environment 🏠

```bash
python3.11 -m venv ~/.venv/3.11
source ~/.venv/3.11/bin/activate
python --version   # check python version
```

### Step 7: Configure Inventory and Settings ⚙️

⚠️ IMPORTANT: After extracting kubespray, you need to:

- Edit inventory and cluster settings as required by kubespray
- Configure offline settings in `group_vars/all/offline.yml`:
  - Change `YOUR_HOST` to your registry/nginx host IP (reachable from all Kubernetes nodes)

### Step 8: Configure Registries and Hosts 🌐

```bash
ansible-playbook -i inventory/local/hosts.ini playbook/offline-repo.yml
```

### Step 9: Run Kubespray Deployment 🚀

```bash
ansible-playbook -i inventory/local/hosts.ini --become --become-user=root cluster.yml
```

### 📚 What's Included

- 🐳 Kubespray: The Kubernetes deployment tool
- 📦 Container Images: All required container images
- 🔧 Configuration Files: Pre-configured settings
- 📋 Scripts: Installation and setup scripts
- 🛠️ Dependencies: All necessary dependencies

### 🎯 Complete Installation Flow

```bash
# 1. Extract files from Docker image
cid=$(docker create akamrani/offline-kubespray:latest) && \
  docker cp "$cid:/data/install-k8s-offline" ./install-k8s-offline && \
  docker rm "$cid"

# 2. Navigate to directory
cd ./install-k8s-offline

# 3. Run setup scripts in order
./setup-container.sh
./start-nginx.sh
./setup-offline.sh
./setup-py.sh
./start-registry.sh
./load-push-all-images.sh
./extract-kubespray.sh

# 4. Install required packages
sudo apt update
sudo apt install -y python3 python3-venv python3-pip
pip install ansible # Use specific version for compatibility

# 5. Setup virtual environment
python3.11 -m venv ~/.venv/3.11
source ~/.venv/3.11/bin/activate

# 6. Navigate to kubespray directory
cd kubespray-{version}

# 7. Configure offline settings
vim group_vars/all/offline.yml  # Change YOUR_HOST to your registry IP

# 8. Configure registries on all nodes
ansible-playbook -i inventory/mycluster/hosts.ini offline-repo.yml

# 9. Deploy Kubernetes cluster
ansible-playbook -i inventory/mycluster/hosts.ini --become --become-user=root cluster.yml  -e "unsafe_show_logs=true" -vvv
```

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
pip install ansible-core==2.16.14
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
