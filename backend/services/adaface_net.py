"""
AdaFace IR-50 network architecture.

This defines the IResNet-50 backbone used by AdaFace for face recognition.
Architecture matches the official AdaFace checkpoint format from:
https://github.com/mk-minchul/AdaFace

The model accepts 112x112 BGR face crops and outputs 512-d embeddings.
"""

from collections import namedtuple

import torch
import torch.nn as nn
from torch.nn import (
    BatchNorm1d,
    BatchNorm2d,
    Conv2d,
    Dropout,
    Linear,
    MaxPool2d,
    Module,
    PReLU,
    Sequential,
)

# ──────────────────────────────────────────────
#  Building Blocks
# ──────────────────────────────────────────────


class Flatten(Module):
    """Flatten tensor to (batch_size, -1)."""

    def forward(self, x):
        return x.view(x.size(0), -1)


class BottleneckIR(Module):
    """Improved ResNet bottleneck block (no Squeeze-Excitation)."""

    def __init__(self, in_channel, depth, stride):
        super().__init__()
        if in_channel == depth:
            self.shortcut_layer = MaxPool2d(1, stride)
        else:
            self.shortcut_layer = Sequential(
                Conv2d(in_channel, depth, (1, 1), stride, bias=False),
                BatchNorm2d(depth),
            )
        self.res_layer = Sequential(
            BatchNorm2d(in_channel),
            Conv2d(in_channel, depth, (3, 3), (1, 1), 1, bias=False),
            BatchNorm2d(depth),
            PReLU(depth),
            Conv2d(depth, depth, (3, 3), stride, 1, bias=False),
            BatchNorm2d(depth),
        )

    def forward(self, x):
        shortcut = self.shortcut_layer(x)
        res = self.res_layer(x)
        return res + shortcut


# ──────────────────────────────────────────────
#  Block Configuration
# ──────────────────────────────────────────────

# Named tuple for block configs: (input_channels, output_channels, stride)
BlockConfig = namedtuple("Block", ["in_channel", "depth", "stride"])


def _get_block(in_channel, depth, num_units, stride=2):
    """Create a sequence of block configs for one stage."""
    return [BlockConfig(in_channel, depth, stride)] + [
        BlockConfig(depth, depth, 1) for _ in range(num_units - 1)
    ]


def _get_blocks(num_layers):
    """Get the block configuration for a given number of layers."""
    if num_layers == 50:
        return [
            _get_block(in_channel=64, depth=64, num_units=3),
            _get_block(in_channel=64, depth=128, num_units=4),
            _get_block(in_channel=128, depth=256, num_units=14),
            _get_block(in_channel=256, depth=512, num_units=3),
        ]
    elif num_layers == 101:
        return [
            _get_block(in_channel=64, depth=64, num_units=3),
            _get_block(in_channel=64, depth=128, num_units=13),
            _get_block(in_channel=128, depth=256, num_units=30),
            _get_block(in_channel=256, depth=512, num_units=3),
        ]
    else:
        raise ValueError(f"Unsupported num_layers: {num_layers}. Use 50 or 101.")


# ──────────────────────────────────────────────
#  Backbone
# ──────────────────────────────────────────────


class Backbone(Module):
    """
    IResNet backbone for face recognition.

    Architecture:
    - Input: 112x112x3 (BGR)
    - Conv(3→64) + BN + PReLU
    - 4 stages of BottleneckIR: [3, 4, 14, 3] for IR-50
    - BN + Dropout + Flatten + FC(512*7*7→512) + BN
    - Output: 512-d embedding
    """

    def __init__(self, input_size=(112, 112), num_layers=50, drop_ratio=0.4):
        super().__init__()
        assert input_size == (112, 112), "AdaFace requires 112x112 input"
        blocks = _get_blocks(num_layers)

        self.input_layer = Sequential(
            Conv2d(3, 64, (3, 3), 1, 1, bias=False),
            BatchNorm2d(64),
            PReLU(64),
        )

        # Build all bottleneck blocks as a flat Sequential
        # (this matches the checkpoint key naming: body.0, body.1, ..., body.23)
        modules = []
        for block in blocks:
            for bottleneck in block:
                modules.append(
                    BottleneckIR(
                        bottleneck.in_channel,
                        bottleneck.depth,
                        bottleneck.stride,
                    )
                )
        self.body = Sequential(*modules)

        # Output: 7x7 feature map → 512-d embedding
        self.output_layer = Sequential(
            BatchNorm2d(512),
            Dropout(drop_ratio),
            Flatten(),
            Linear(512 * 7 * 7, 512),
            BatchNorm1d(512, affine=False),
        )

    def forward(self, x):
        x = self.input_layer(x)
        x = self.body(x)
        x = self.output_layer(x)
        return x


# ──────────────────────────────────────────────
#  Factory Functions
# ──────────────────────────────────────────────


def build_model(architecture="ir_50"):
    """Build an AdaFace backbone model."""
    if architecture == "ir_50":
        return Backbone(input_size=(112, 112), num_layers=50)
    elif architecture == "ir_101":
        return Backbone(input_size=(112, 112), num_layers=101)
    else:
        raise ValueError(f"Unknown architecture: {architecture}. Use 'ir_50' or 'ir_101'.")


def load_pretrained_model(architecture="ir_50", checkpoint_path=None):
    """
    Load an AdaFace model with pretrained weights.

    Args:
        architecture: 'ir_50' or 'ir_101'
        checkpoint_path: Path to the .ckpt file

    Returns:
        Loaded model in eval mode
    """
    model = build_model(architecture)

    if checkpoint_path is None:
        raise ValueError("checkpoint_path is required")

    # AdaFace checkpoints store weights under 'state_dict' with 'model.' prefix
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state_dict = checkpoint.get("state_dict", checkpoint)

    # Strip 'model.' prefix from keys and skip training-only head layers
    model_state_dict = {}
    skip_prefixes = ("head.", "loss.", "margin.")  # training-only layers
    for key, val in state_dict.items():
        clean_key = key[6:] if key.startswith("model.") else key
        if any(clean_key.startswith(p) for p in skip_prefixes):
            continue
        model_state_dict[clean_key] = val

    model.load_state_dict(model_state_dict, strict=True)
    model.eval()

    return model
