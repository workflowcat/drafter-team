"""Convert the cached v3 checkpoint to BF16, without constructing a model.

Run on the Mac, outside the sandbox. Only small tensor blocks enter MLX; the
source cache is read-only and an existing destination is never overwritten.
parakeet-mlx 0.5.3 utils.from_pretrained accepts config.json + model.safetensors
and casts ALL model.parameters() to BF16 already. No learned layer requires an
FP32 exception. audio.PreprocessArgs._filterbanks and attention.*Encoding._pe
are runtime FP32 buffers, not checkpoint parameters; leave their code alone.
"""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from voice_settings import FAST, FAST_BF16

WIDTHS = {'F32': 4, 'F16': 2, 'BF16': 2, 'F64': 8, 'I64': 8, 'I32': 4,
          'I16': 2, 'I8': 1, 'U64': 8, 'U32': 4, 'U16': 2, 'U8': 1, 'BOOL': 1}
BLOCK = 4 * 1024 * 1024


def target_dtype(name, dtype):
    # Defensive preservation if a future exporter includes these buffers.
    if name.rsplit('.', 1)[-1] in ('_pe', '_filterbanks'):
        return dtype
    return 'BF16' if dtype in ('F32', 'F16') else dtype


def read_header(path):
    with Path(path).open('rb') as f:
        raw = f.read(8)
        if len(raw) != 8:
            raise ValueError('Missing safetensors header')
        length, = struct.unpack('<Q', raw)
        if not 2 <= length <= 16 * 1024 * 1024:
            raise ValueError('Invalid safetensors header size')
        header = json.loads(f.read(length))
    return header, 8 + length


def plan(header, payload_size):
    """Validate the source and calculate contiguous output offsets, without MLX."""
    result = {}
    if '__metadata__' in header:
        result['__metadata__'] = header['__metadata__']
    cursor = out = 0
    tensors = sorted(((k, v) for k, v in header.items() if k != '__metadata__'),
                     key=lambda kv: kv[1]['data_offsets'])
    for name, tensor in tensors:
        dtype, shape = tensor['dtype'], tensor['shape']
        if dtype not in WIDTHS or any(type(n) is not int or n < 0 for n in shape):
            raise ValueError(f'Unsupported tensor: {name}')
        start, end = tensor['data_offsets']
        if start != cursor or end - start != math.prod(shape) * WIDTHS[dtype]:
            raise ValueError(f'Invalid tensor offsets: {name}')
        cursor = end
        target = target_dtype(name, dtype)
        size = math.prod(shape) * WIDTHS[target]
        result[name] = dict(dtype=target, shape=shape, data_offsets=[out, out + size])
        out += size
    if cursor != payload_size or not tensors:
        raise ValueError('Checkpoint payload size does not match header')
    return result


def write_weights(source, destination, cast):
    """Streaming serializer. `cast(bytes, source_dtype)` makes this GPU-free testable."""
    header, base = read_header(source)
    target = plan(header, Path(source).stat().st_size - base)
    encoded = json.dumps(target, separators=(',', ':'), ensure_ascii=False).encode()
    encoded += b' ' * (-len(encoded) % 8)
    with Path(source).open('rb') as src, Path(destination).open('xb') as dst:
        dst.write(struct.pack('<Q', len(encoded)))
        dst.write(encoded)
        for name, tensor in target.items():
            if name == '__metadata__':
                continue
            old = header[name]
            start, end = old['data_offsets']
            src.seek(base + start)
            remaining = end - start
            while remaining:
                block = src.read(min(BLOCK, remaining))
                if not block:
                    raise ValueError('Truncated source checkpoint')
                remaining -= len(block)
                if old['dtype'] != tensor['dtype']:
                    converted = cast(block, old['dtype'])
                    if len(converted) != len(block) // WIDTHS[old['dtype']] * WIDTHS[tensor['dtype']]:
                        raise ValueError('Cast returned the wrong byte count')
                    block = converted
                dst.write(block)
        dst.flush()
        os.fsync(dst.fileno())
    actual, output_base = read_header(destination)
    plan(actual, Path(destination).stat().st_size - output_base)


def convert(source, destination, cast):
    source, destination = Path(source).resolve(), Path(destination).expanduser().resolve()
    repo_roots = [ROOT] + [p for p in ROOT.parents if (p / '.git').exists()]
    if any(destination == root or root in destination.parents for root in repo_roots):
        raise ValueError('Converted models must live outside the repository')
    if destination.exists():
        raise FileExistsError(f'Destination already exists: {destination}')
    config = source / 'config.json'
    if not isinstance(json.loads(config.read_text()), dict):
        raise ValueError('config.json must be an object')
    weights = source / 'model.safetensors'
    header, base = read_header(weights)
    plan(header, weights.stat().st_size - base)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.parakeet-bf16-', dir=destination.parent) as folder:
        stage = Path(folder) / 'model'
        stage.mkdir()
        shutil.copyfile(config, stage / 'config.json')
        write_weights(weights, stage / 'model.safetensors', cast)
        # The source's vocabulary and preprocessing settings are embedded in config.
        # Rename only a complete directory; on failure no partial destination remains.
        if destination.exists():
            raise FileExistsError(destination)
        stage.rename(destination)
    before = weights.stat().st_size + config.stat().st_size
    after = sum(p.stat().st_size for p in destination.iterdir())
    print(f'Source: {source}\nOutput: {destination}\n'
          f'Before: {before:,} bytes ({before / 1e9:.3f} GB)\n'
          f'After:  {after:,} bytes ({after / 1e9:.3f} GB); {after / before:.1%} of source')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, help='Local snapshot directory; default: cached current v3')
    parser.add_argument('--output', type=Path, default=Path(FAST_BF16).expanduser())
    args = parser.parse_args()
    source = args.source
    if source is None:
        from huggingface_hub import hf_hub_download
        source = Path(hf_hub_download(FAST, 'model.safetensors', local_files_only=True)).parent
        hf_hub_download(FAST, 'config.json', local_files_only=True)
    # No from_pretrained, no model object, no inference. Import MLX only on execution.
    import guard
    guard.start(3_000_000_000 / 2**30, every=0.1, hold=1, spike=0)
    import mlx.core as mx
    import numpy as np
    mx.set_memory_limit(3_000_000_000)
    mx.set_cache_limit(64 * 2**20)

    def cast(block, dtype):
        values = np.frombuffer(block, dtype={'F32': '<f4', 'F16': '<f2'}[dtype])
        converted = mx.array(values).astype(mx.bfloat16).view(mx.uint16)
        mx.eval(converted)
        result = np.asarray(converted).astype('<u2', copy=False).tobytes()
        del converted
        mx.clear_cache()
        return result

    convert(source, args.output, cast)


if __name__ == '__main__':
    main()
