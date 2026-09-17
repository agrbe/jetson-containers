# transformers 5.x compatibility for TensorRT-LLM 1.2.x (written against 4.57.3).
# Restores modeling_utils symbols removed in the v5 cleanup.
#
# load_sharded_checkpoint is copied verbatim from transformers v4.57.3
# (src/transformers/modeling_utils.py, Apache-2.0) with two mechanical changes:
#   - module-level names inlined (WEIGHTS_INDEX_NAME, SAFE_WEIGHTS_INDEX_NAME,
#     safe_load_file, check_torch_load_is_safe -> weights_only=True is kept)
#   - upstream bug fixed: the unexpected-keys branch mislabeled its message as
#     "Missing key(s)"; it now reads "Unexpected key(s)".
import gc
import json
import os
from functools import partial

import torch
from safetensors.torch import load_file as safe_load_file

import transformers.modeling_utils as _tmu

WEIGHTS_INDEX_NAME = "pytorch_model.bin.index.json"
SAFE_WEIGHTS_INDEX_NAME = "model.safetensors.index.json"

if not hasattr(_tmu, "get_parameter_device"):
    def get_parameter_device(module):
        return next(module.parameters()).device

    def get_parameter_dtype(module):
        return next(module.parameters()).dtype

    _tmu.get_parameter_device = get_parameter_device
    _tmu.get_parameter_dtype = get_parameter_dtype

if not hasattr(_tmu, "load_sharded_checkpoint"):
    def load_sharded_checkpoint(model, folder, strict=True, prefer_safe=True):
        """
        This is the same as
        [`torch.nn.Module.load_state_dict`](https://pytorch.org/docs/stable/generated/torch.nn.Module.html?highlight=load_state_dict#torch.nn.Module.load_state_dict)
        but for a sharded checkpoint.

        This load is performed efficiently: each checkpoint shard is loaded one by one in RAM and deleted after being
        loaded in the model.

        Args:
            model (`torch.nn.Module`): The model in which to load the checkpoint.
            folder (`str` or `os.PathLike`): A path to a folder containing the sharded checkpoint.
            strict (`bool`, *optional*, defaults to `True`):
                Whether to strictly enforce that the keys in the model state dict match the keys in the sharded checkpoint.
            prefer_safe (`bool`, *optional*, defaults to `False`):
                If both safetensors and PyTorch save files are present in checkpoint and `prefer_safe` is True, the
                safetensors files will be loaded. Otherwise, PyTorch files are always loaded when possible.

        Returns:
            `NamedTuple`: A named tuple with `missing_keys` and `unexpected_keys` fields
                - `missing_keys` is a list of str containing the missing keys
                - `unexpected_keys` is a list of str containing the unexpected keys
        """
        # Load the index
        index_file = os.path.join(folder, WEIGHTS_INDEX_NAME)
        safe_index_file = os.path.join(folder, SAFE_WEIGHTS_INDEX_NAME)

        index_present = os.path.isfile(index_file)
        safe_index_present = os.path.isfile(safe_index_file)

        if not index_present and not safe_index_present:
            filenames = (WEIGHTS_INDEX_NAME, SAFE_WEIGHTS_INDEX_NAME)
            raise ValueError(f"Can't find a checkpoint index ({' or '.join(filenames)}) in {folder}.")

        load_safe = safe_index_present and (prefer_safe or not index_present)
        load_index = safe_index_file if load_safe else index_file

        with open(load_index, "r", encoding="utf-8") as f:
            index = json.load(f)

        shard_files = list(set(index["weight_map"].values()))

        # If strict=True, error before loading any of the state dicts.
        loaded_keys = index["weight_map"].keys()
        model_keys = model.state_dict().keys()
        missing_keys = [key for key in model_keys if key not in loaded_keys]
        unexpected_keys = [key for key in loaded_keys if key not in model_keys]
        if strict and (len(missing_keys) > 0 or len(unexpected_keys) > 0):
            error_message = f"Error(s) in loading state_dict for {model.__class__.__name__}"
            if len(missing_keys) > 0:
                str_missing_keys = ",".join([f'"{k}"' for k in missing_keys])
                error_message += f"\nMissing key(s): {str_missing_keys}."
            if len(unexpected_keys) > 0:
                str_unexpected_keys = ",".join([f'"{k}"' for k in unexpected_keys])
                error_message += f"\nUnexpected key(s): {str_unexpected_keys}."
            raise RuntimeError(error_message)

        if load_safe:
            loader = safe_load_file
        else:
            loader = partial(torch.load, map_location="cpu", weights_only=True)

        for shard_file in shard_files:
            state_dict = loader(os.path.join(folder, shard_file))
            model.load_state_dict(state_dict, strict=False)

            # Make sure memory is freed before we load the next state dict.
            del state_dict
            gc.collect()

        # Return the same thing as PyTorch load_state_dict function.
        return torch.nn.modules.module._IncompatibleKeys(missing_keys, unexpected_keys)

    _tmu.load_sharded_checkpoint = load_sharded_checkpoint
