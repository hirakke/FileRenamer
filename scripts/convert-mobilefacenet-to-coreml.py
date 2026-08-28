#!/usr/bin/env python3
"""Convert Qualcomm MobileFaceNet v0.61.0 ONNX to a single-face Core ML model.

The Qualcomm export accepts two face tensors and returns two TTA embeddings. The
FileRenamer wrapper supplies one face to both inputs, selects the first 128-vector,
and L2 normalises it. Runtime input stays RGB NCHW float32 in the documented 0...1
range because the upstream graph performs torchvision normalisation internally.

Conversion environment used for the checked-in artifact:
  Python 3.9.6, coremltools 9.0, onnx 1.19.1, onnx2torch 1.5.15,
  torch 2.8.0, torchvision 0.23.0, numpy 2.0.2.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
import torch.nn.functional as F
from onnx2torch import convert
from onnx.reference import ReferenceEvaluator


MODEL_IDENTIFIER = "qualcomm.mobilefacenet"
MODEL_VERSION = "0.61.0"
MODEL_DIMENSION = 128
INPUT_SHAPE = (1, 3, 112, 112)


class SingleFaceEmbedding(torch.nn.Module):
    def __init__(self, pair_model: torch.nn.Module) -> None:
        super().__init__()
        self.pair_model = pair_model

    def forward(self, input: torch.Tensor) -> torch.Tensor:
        # The Qualcomm graph performs flip TTA internally for each input.
        paired = self.pair_model(input, input)
        averaged = paired[:, :MODEL_DIMENSION].mean(dim=0, keepdim=True)
        return F.normalize(averaged, p=2, dim=1, eps=1e-12)


def make_onnx2torch_compatible(model: onnx.ModelProto) -> onnx.ModelProto:
    """Backport semantically-compatible Reshape/Split nodes to opset 17.

    Qualcomm's v0.61.0 export declares opset 21 and emits allowzero=1, while
    both shape tensors contain only positive values and -1. onnx2torch 1.5.15
    supports the otherwise-identical Reshape-14 behavior. Refuse conversion if
    the graph no longer has the exact properties this compatibility rewrite
    relies on.
    """
    imports = [item for item in model.opset_import if item.domain == ""]
    if len(imports) != 1 or imports[0].version != 21:
        raise RuntimeError("Expected Qualcomm MobileFaceNet ONNX opset 21")

    initializers = {
        initializer.name: onnx.numpy_helper.to_array(initializer)
        for initializer in model.graph.initializer
    }
    flip_end = initializers.get("val_25")
    if flip_end is None or flip_end.tolist() != [np.iinfo(np.int64).min]:
        raise RuntimeError("Unexpected flip Slice endpoint")
    reshape_nodes = [node for node in model.graph.node if node.op_type == "Reshape"]
    if len(reshape_nodes) != 2:
        raise RuntimeError(f"Expected exactly two Reshape nodes, got {len(reshape_nodes)}")

    compatible = copy.deepcopy(model)
    for index, initializer in enumerate(compatible.graph.initializer):
        if initializer.name == "val_25":
            # For a fixed 112-wide input, -113 is equivalent to INT64_MIN as
            # an exclusive negative-step endpoint, but converts with a stable
            # static shape in coremltools.
            compatible.graph.initializer[index].CopyFrom(
                onnx.numpy_helper.from_array(
                    np.asarray([-INPUT_SHAPE[3] - 1], dtype=np.int64),
                    name="val_25",
                )
            )
    for node in compatible.graph.node:
        if node.op_type != "Reshape":
            continue
        attributes = {
            attribute.name: onnx.helper.get_attribute_value(attribute)
            for attribute in node.attribute
        }
        if attributes != {"allowzero": 1}:
            raise RuntimeError(f"Unexpected Reshape attributes on {node.name}: {attributes}")
        if len(node.input) != 2 or node.input[1] not in initializers:
            raise RuntimeError(f"Reshape shape is not constant on {node.name}")
        shape = initializers[node.input[1]]
        if np.any(shape == 0):
            raise RuntimeError(f"Reshape uses allowzero semantics on {node.name}")
        del node.attribute[:]

    split_nodes = [node for node in compatible.graph.node if node.op_type == "Split"]
    if len(split_nodes) != 1:
        raise RuntimeError(f"Expected exactly one Split node, got {len(split_nodes)}")
    split = split_nodes[0]
    split_attributes = {
        attribute.name: onnx.helper.get_attribute_value(attribute)
        for attribute in split.attribute
    }
    if split_attributes != {"axis": 0}:
        raise RuntimeError(f"Unexpected Split attributes: {split_attributes}")
    if len(split.input) != 2 or split.input[1] not in initializers:
        raise RuntimeError("Split sizes are not constant")
    if initializers[split.input[1]].tolist() != [1, 1, 1, 1]:
        raise RuntimeError("Unexpected Split sizes")

    for item in compatible.opset_import:
        if item.domain == "":
            item.version = 17
    onnx.checker.check_model(compatible)
    return compatible


def verify_compatibility_rewrite(
    original: onnx.ModelProto,
    compatible: onnx.ModelProto,
    sample: np.ndarray,
) -> None:
    feeds = {"img1": sample, "img2": np.flip(sample, axis=3).copy()}
    original_output = ReferenceEvaluator(original).run(None, feeds)[0]
    compatible_output = ReferenceEvaluator(compatible).run(None, feeds)[0]
    if not np.array_equal(original_output, compatible_output):
        maximum_error = float(np.max(np.abs(original_output - compatible_output)))
        raise RuntimeError(
            f"ONNX compatibility rewrite changed model output: {maximum_error}"
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def convert_model(onnx_path: Path, output_path: Path) -> dict[str, object]:
    if output_path.exists():
        raise FileExistsError(f"Refusing to replace existing output: {output_path}")

    onnx_model = onnx.load(str(onnx_path), load_external_data=True)
    onnx.checker.check_model(onnx_model)
    sample_numpy = np.linspace(
        0, 1, int(np.prod(INPUT_SHAPE)), dtype=np.float32
    ).reshape(INPUT_SHAPE)
    compatible_model = make_onnx2torch_compatible(onnx_model)
    verify_compatibility_rewrite(onnx_model, compatible_model, sample_numpy)
    pair_model = convert(compatible_model).eval()
    wrapper = SingleFaceEmbedding(pair_model).eval()

    sample = torch.from_numpy(sample_numpy)
    with torch.no_grad():
        reference = wrapper(sample)
    if tuple(reference.shape) != (1, MODEL_DIMENSION):
        raise RuntimeError(f"Unexpected reference shape: {tuple(reference.shape)}")

    traced = torch.jit.trace(wrapper, sample, strict=True)
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name="input",
                shape=INPUT_SHAPE,
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
    )
    coreml_model.short_description = (
        "MobileFaceNet single-face embedding with flip TTA and L2 normalisation"
    )
    coreml_model.input_description["input"] = (
        "112x112 RGB NCHW Float32 face tensor with values in 0...1"
    )
    coreml_model.output_description["embedding"] = (
        "128-dimensional L2-normalised face embedding"
    )
    coreml_model.user_defined_metadata.update(
        {
            "com.filerenamer.model.identifier": MODEL_IDENTIFIER,
            "com.filerenamer.model.version": MODEL_VERSION,
            "com.filerenamer.model.dimension": str(MODEL_DIMENSION),
            "com.filerenamer.model.source": (
                "https://huggingface.co/qualcomm/MobileFaceNet"
            ),
            "com.filerenamer.model.source_onnx_sha256": sha256(onnx_path),
            "com.filerenamer.model.license": "Apache-2.0",
        }
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(output_path))

    prediction = coreml_model.predict({"input": sample.numpy()})["embedding"]
    prediction = np.asarray(prediction, dtype=np.float32).reshape(1, -1)
    reference_numpy = reference.detach().numpy()
    maximum_error = float(np.max(np.abs(prediction - reference_numpy)))
    norm = float(np.linalg.norm(prediction))
    if prediction.shape != (1, MODEL_DIMENSION):
        raise RuntimeError(f"Unexpected Core ML shape: {prediction.shape}")
    if not np.isfinite(prediction).all():
        raise RuntimeError("Core ML output contains a non-finite value")
    if abs(norm - 1) > 1e-4:
        raise RuntimeError(f"Core ML output is not L2-normalised: {norm}")
    if maximum_error > 2e-3:
        raise RuntimeError(f"Core ML output differs from PyTorch: {maximum_error}")

    return {
        "input_shape": list(INPUT_SHAPE),
        "output_shape": list(prediction.shape),
        "output_l2_norm": norm,
        "maximum_reference_error": maximum_error,
        "source_onnx_sha256": sha256(onnx_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = convert_model(args.onnx.resolve(), args.output.resolve())
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
