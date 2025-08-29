# The Definitive Guide to Docker-in-Docker with Gitea Actions

It has come to my attention that someone is wrong on the _Internet_. Actually, not just someone—seemingly **everyone** writing guides about setting up Docker-in-Docker (DIND) with Gitea Actions. The multitudes of tutorials, blog posts, and StackOverflow answers all seem to miss critical architectural limitations and security considerations that make their solutions either incomplete, insecure, or simply non-functional in real-world scenarios.

This guide presents a **complete, almost production-ready example** for isolated Docker-in-Docker CI/CD using Gitea Actions with proper security boundaries and full functionality.

## ⚠️ Enterprise Security Warning

**This setup is intended for development and testing environments.** For true enterprise-grade production deployments, additional security measures are required:

### Critical Security Enhancements Needed for Enterprise-grade Production

1. **Network Firewall Protection**
   - Deploy firewall rules to isolate the CI/CD network from internal corporate networks
   - Implement egress filtering to prevent build containers from accessing internal services
   - Use network segmentation to contain potential container breakouts
   - Consider running the entire stack in a separate VLAN or VPC

2. **Container Image Security**
   - Gitea needs a feature that only white listed images are allowed to run in priveleged-mode
   - Only allow pre-approved, security-scanned base images
   - Implement image signing and verification workflows
   - Regular vulnerability scanning of all container images

3. **DIND Image Hardening**
   - Remove unnecessary packages and tools from the custom DIND image
   - Implement read-only root filesystem where possible
   - Use distroless or minimal base images

4. Plenty more with various compliance stuff but the above state is a good start.

**The configuration presented here prioritizes functionality and ease of setup over maximum security hardening.**

## Requirements & Use Case

We need a CI/CD environment that provides:

- **Complete isolation** from the host Docker daemon
- **Docker functionality** available to both services and build steps
- **Self-contained deployment** with no external dependencies
- **Proper security boundaries** between jobs and the host system
- **Full Docker API access** for build, test, and deployment workflows

## The Problem: Gitea Actions Limitations

Gitea's `act_runner` is based on the excellent `nektos/act` project, but it has several critical limitations when compared to GitHub Actions:

### 1. Incomplete Services Support
- **Incomplete `volumes` mounting** capability for services in workflow YAML
- **Limited `options` support** compared to full `docker run` functionality
- **No `command` override** support in the `services:` section

### 2. Docker Configuration Challenges
- Cannot mount `daemon.json` configuration files into service containers
- No way to inject custom Docker daemon startup parameters
- Services are treated as immutable "black boxes"

### 3. GitHub Actions Parity Issues
GitHub Actions itself doesn't support:
- `command` overrides in the `services:` section

## Why Custom DIND Images Are Required

Standard `docker:dind` images:
- Listen on Unix socket by default (`/var/run/docker.sock`)
- Have TLS enabled by default (requires certificates)
- Cannot be configured via environment variables for network settings
- Cannot be customized through workflow YAML due to services limitations

**Our solution:** Build a custom DIND image with hardcoded configuration:
```dockerfile
FROM docker:dind
CMD ["dockerd", "--host", "tcp://0.0.0.0:2376", "--tls=false"]
```

## Architecture Overview: Triple-Nested Isolation

Our architecture provides three layers of Docker isolation:

1. **Host Docker** (docker-compose level) - Orchestrates the entire CI/CD stack
2. **Runner DIND** (act_runner execution environment) - Provides Docker services for workflows  
3. **Build DIND** (workflow build steps) - Enables Docker operations within build containers

This triple nesting is essential because:
- **Services** run in the runner's Docker daemon
- **Build steps** run inside containers with no Docker daemon access
- **Each layer** provides different security boundaries and functional contexts

## Step-by-Step Implementation

### Step 1: Create the Custom DIND Image

**Dockerfile:**
```dockerfile
FROM docker:dind

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD docker version || exit 1

CMD ["dockerd", "--host", "tcp://0.0.0.0:2376", "--tls=false"]
```

### Step 2: Configure Gitea for Actions

> **⚠️ Security Note:** The `INTERNAL_TOKEN` and `JWT_SECRET` values in the example `app.ini` below are provided for convenience to make this docker-compose example work out-of-the-box. **In production deployments, these tokens MUST be regenerated using fresh, cryptographically secure random values.** Never use these example tokens in any environment beyond local development and testing.

**app.ini:**
```ini
APP_NAME = Gitea: Git with a cup of tea
RUN_MODE = prod
WORK_PATH = /data/gitea

[actions]
ENABLED = true

[repository]
ROOT = /data/git/repositories

[repository.local]
LOCAL_COPY_PATH = /data/gitea/tmp/local-repo

[repository.upload]
TEMP_PATH = /data/gitea/uploads

[server]
APP_DATA_PATH = /data/gitea
DOMAIN = localhost
SSH_DOMAIN = localhost
HTTP_PORT = 3000
ROOT_URL = http://localhost:3000
LOCAL_ROOT_URL= http://gitea:3000
DISABLE_SSH = false
SSH_PORT = 2222
SSH_LISTEN_PORT = 22
LFS_START_SERVER = false

[database]
PATH = /data/gitea/gitea.db
DB_TYPE = sqlite3
HOST = localhost:3306
NAME = gitea
USER = root
PASSWD = 
LOG_SQL = false

[indexer]
ISSUE_INDEXER_PATH = /data/gitea/indexers/issues.bleve

[session]
PROVIDER_CONFIG = /data/gitea/sessions

[picture]
AVATAR_UPLOAD_PATH = /data/gitea/avatars
REPOSITORY_AVATAR_UPLOAD_PATH = /data/gitea/repo-avatars

[attachment]
PATH = /data/gitea/attachments

[log]
MODE = console
LEVEL = info
ROOT_PATH = /data/gitea/log

[security]
INSTALL_LOCK = true
REVERSE_PROXY_LIMIT = 1
REVERSE_PROXY_TRUSTED_PROXIES = *
INTERNAL_TOKEN = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYmYiOjE3NTY0NzI0OTF9.lXfJEgeQCkXcQx3VKm-TwLQktTYrccm_JK1P0xiDmEw

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = false

[lfs]
PATH = /data/git/lfs

[oauth2]
JWT_SECRET = nq7Fpd5bAPFHOWHZJJah2rKfXdC3pKaF0pMgtaQwAdw
```

### Step 3: Docker Compose Configuration

The complete docker-compose.yml orchestrates six services with proper dependency management:

**docker-compose.yml:**
```yaml
services:
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    ports:
      - "3000:3000"
      - "2222:22"
    volumes:
      - gitea_data:/data
      - ./app.ini:/data/gitea/conf/app.ini:ro
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - USER_UID=1000
      - USER_GID=1000
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    restart: unless-stopped

  dind:
    build: .
    container_name: dind
    privileged: true
    volumes:
      - dind_data:/var/lib/docker
    environment:
      - DOCKER_HOST=tcp://localhost:2376
    healthcheck:
      test: ["CMD", "docker", "info"]
      interval: 10s
      timeout: 10s
      retries: 5
      start_period: 30s
    restart: unless-stopped

  registry:
    image: registry:2
    container_name: registry
    volumes:
      - registry_data:/var/lib/registry
    environment:
      - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5000/v2/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    restart: unless-stopped

  image-builder:
    image: docker:dind
    container_name: image-builder
    depends_on:
      registry:
        condition: service_healthy
      dind:
        condition: service_healthy
    volumes:
      - ./Dockerfile:/workspace/Dockerfile
      - dind_data:/var/lib/docker
    working_dir: /workspace
    command: >
      sh -c "
        export DOCKER_HOST=tcp://dind:2376
        export DOCKER_TLS_VERIFY=\"\"
        echo 'Building and pushing DIND image to local registry...'
        docker build -t registry:5000/dind-plain:latest .
        docker push registry:5000/dind-plain:latest
        echo 'Image build and push complete!'
      "
    restart: "no"

  runner-configurator:
    image: gitea/gitea:latest
    container_name: runner-configurator
    depends_on:
      gitea:
        condition: service_healthy
    volumes:
      - runner_config:/config
      - ./app.ini:/data/gitea/conf/app.ini:ro
    command: >
      sh -c "
        echo 'Gitea is healthy, proceeding...'
        echo 'Generating runner token...'
        su - git -c 'cd /data && /usr/local/bin/gitea actions generate-runner-token' > /config/token
        echo 'Creating runner config...'
        GITEA_IP=$$(getent hosts gitea | awk '{print $$1}')
        REGISTRY_IP=$$(getent hosts registry | awk '{print $$1}')
        echo \"Resolved Gitea IP: $$GITEA_IP\"
        cat > /config/config.yaml << EOF
      log:
        level: info
      runner:
        file: .runner
        capacity: 1
        timeout: 3h
        insecure: false
        fetch_timeout: 5s
        fetch_interval: 2s
        labels:
          - 'ubuntu-latest:docker://gitea/runner-images:ubuntu-latest'
          - 'ubuntu-22.04:docker://gitea/runner-images:ubuntu-22.04'
          - 'ubuntu-20.04:docker://gitea/runner-images:ubuntu-20.04'
          - 'linux:docker://gitea/runner-images:ubuntu-latest'
      cache:
        enabled: true
        dir: '/tmp/cache'
        host: ''
        port: 0
      container:
        network_mode: bridge
        enable_ipv6: false
        privileged: true
        valid_volumes:
          - '**'
        docker_host: tcp://dind:2376
        options: '--add-host=gitea:$$GITEA_IP --add-host=registry:$$REGISTRY_IP'
      host:
        workdir_parent: /tmp
      EOF
        echo 'Configuration complete!'
      "
    restart: "no"

  admin-setup:
    image: gitea/gitea:latest
    container_name: admin-setup
    depends_on:
      gitea:
        condition: service_healthy
    environment:
      - GITEA_URL=http://gitea:3000
    volumes:
      - gitea_data:/data
      - ./app.ini:/data/gitea/conf/app.ini:ro
    command: >
      sh -c "
        echo 'Creating admin user...'
        su - git -c '/usr/local/bin/gitea admin user create --admin --username admin --password admin --email admin@localhost.local --must-change-password=false' || echo 'Admin user already exists'
        echo 'Admin setup complete!'
      "
    restart: "no"

  runner:
    image: gitea/act_runner:latest
    container_name: runner
    depends_on:
      gitea:
        condition: service_healthy
      dind:
        condition: service_healthy
      admin-setup:
        condition: service_completed_successfully
      runner-configurator:
        condition: service_completed_successfully
      image-builder:
        condition: service_completed_successfully
    volumes:
      - runner_config:/config:ro
      - runner_data:/data
    environment:
      - DOCKER_HOST=tcp://dind:2376
      - DOCKER_TLS_VERIFY=""
      - GITEA_INSTANCE_URL=http://gitea:3000
      - GITEA_RUNNER_REGISTRATION_TOKEN_FILE=/config/token
      - CONFIG_FILE=/config/config.yaml
    command: >
      sh -c "
        echo 'All dependencies ready, token file available...'
        echo 'Registering and starting runner...'
        act_runner register --config /config/config.yaml --no-interactive
        act_runner daemon --config /config/config.yaml
      "
    restart: unless-stopped

volumes:
  gitea_data:
  dind_data:
  runner_config:
  runner_data:
  registry_data:
```

### Step 4: Example Workflow

**.gitea/workflows/test-dind.yml:**
```yaml
name: Test DIND Integration

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  test-docker:
    runs-on: linux
    
    services:
      docker:
        image: registry:5000/dind-plain:latest
    
    env:
      DOCKER_HOST: tcp://docker:2376
      DOCKER_TLS_VERIFY: ""
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Wait
        run: sleep 10
      
      - name: Verify Docker daemon is running
        run: |
          echo "Testing Docker daemon connection..."
          docker info
      
      - name: List running containers
        run: |
          echo "Listing all containers..."
          docker ps -a
      
      - name: Test Docker functionality
        run: |
          echo "Testing basic Docker operations..."
          docker run --rm hello-world
          
      - name: Verify DIND isolation
        run: |
          echo "Testing container isolation..."
          docker run --rm alpine:latest echo "DIND is working perfectly!"
```

## Security Considerations

This architecture provides multiple security boundaries:

- **Host Isolation**: Docker-compose isolates the entire CI/CD stack from the host
- **Runner Isolation**: Each workflow job gets its own Docker environment
- **Build Isolation**: Docker operations in build steps use separate DIND instances
- **Network Isolation**: Partial. Services and builds cannot directly access host resources but can access host network.


## Conclusion

This guide provides a complete examplt of a production-ready solution for Docker-in-Docker with Gitea Actions. The architecture addresses the fundamental limitations of both GitHub Actions and Gitea's act_runner while providing proper security isolation and full Docker functionality.

The key insights that most guides miss:

1. **Custom DIND images are required** due to services configuration limitations
3. **Triple-nested isolation** provides both security and functionality
