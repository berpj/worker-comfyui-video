# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

# Stage 1: System dependencies shared by build and final images
FROM ${BASE_IMAGE} AS system

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=0.22.3
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: Build ComfyUI and its Python environment
FROM system AS base

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli==1.10.3 pip setuptools wheel

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Install ComfyUI
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      COMFY_INSTALL_OPTIONS="--skip-torch-or-directml"; \
    fi; \
    if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia ${COMFY_INSTALL_OPTIONS:-}; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia ${COMFY_INSTALL_OPTIONS:-}; \
    fi

RUN uv pip install -r /comfyui/requirements.txt transformers==5.10.2 comfy-kitchen==0.2.10 \
    && python -c "import torch; print(f'Torch CUDA: {torch.version.cuda}')"

# Change working directory to ComfyUI
WORKDIR /comfyui

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod==1.9.1 requests websocket-client

# Add application code and scripts
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Stage 3: Clean image without installation layers or duplicate Python packages
FROM system AS clean

ENV PIP_NO_INPUT=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}"

COPY --from=base /opt/venv /opt/venv
COPY --from=base /comfyui /comfyui
COPY --from=base /root/.local /root/.local
COPY --from=base /root/.config/comfy-cli /root/.config/comfy-cli
COPY --from=base /handler.py /start.sh /test_input.json /
COPY --from=base /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/comfy-node-install /usr/local/bin/comfy-manager-set-mode /usr/local/bin/

WORKDIR /
CMD ["/start.sh"]

# Stage 4: Download models
FROM base AS downloader

ARG HUGGINGFACE_ACCESS_TOKEN
# Set default model type if none is provided
ARG MODEL_TYPE=none

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/unet models/clip

# Stage 5: Final image
FROM clean AS final

# Copy downloaded models into the final image
COPY --from=downloader /comfyui/models /comfyui/models
