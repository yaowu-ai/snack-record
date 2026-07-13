#!/usr/bin/env python3
import argparse
import os
import re
from pathlib import Path

import numpy as np
from funasr import AutoModel

MODEL_NAMES = (
    "iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    "iic--speech_fsmn_vad_zh-cn-16k-common-pytorch",
    "iic--punc_ct-transformer_cn-en-common-vocab471067-large",
    "iic--speech_campplus_sv_zh-cn_16k-common",
)


def local_model_directories() -> tuple[Path, Path, Path, Path]:
    cache_root = Path(
        os.environ.get("MODELSCOPE_CACHE", Path.home() / ".cache" / "modelscope")
    ).expanduser()
    directories = tuple(
        cache_root / "models" / model_name / "snapshots" / "master"
        for model_name in MODEL_NAMES
    )
    missing = [str(directory) for directory in directories if not directory.is_dir()]
    if missing:
        raise RuntimeError("Local FunASR models are unavailable: " + ", ".join(missing))
    return directories


def normalize_text(text: str) -> str:
    text = text.strip()
    return re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", text)


def relative_time(milliseconds: int) -> str:
    total_seconds = max(0, int(milliseconds)) // 1000
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


class ProgressReporter:
    def __init__(self) -> None:
        self.last_percent = -1.0

    def emit(self, percent: float) -> None:
        percent = max(0.0, min(100.0, percent))
        if percent < 100.0 and percent - self.last_percent < 0.5:
            return
        self.last_percent = percent
        print(f"PROGRESS {percent:.1f}", flush=True)


def audio_duration_ms(value: object) -> float:
    if isinstance(value, (list, tuple)):
        return sum(audio_duration_ms(item) for item in value)
    try:
        array = np.asarray(value)
    except Exception:
        return 0.0
    if array.ndim == 0:
        return 0.0
    sample_count = array.shape[-1]
    batch_count = array.shape[0] if array.ndim > 1 else 1
    return float(sample_count * batch_count) / 16.0


def install_progress_bridge(model: AutoModel, reporter: ProgressReporter, mode: str) -> None:
    original_inference = model.inference
    state = {
        "total_speech_ms": 0.0,
        "processed_speech_ms": 0.0,
        "pending_percent": 8.0,
        "pending_speaker_calls": 0,
    }

    def inference_with_progress(input_value, *args, **kwargs):
        target_model = kwargs.get("model")
        asr_duration = audio_duration_ms(input_value) if target_model is model.model else 0.0
        if isinstance(input_value, (list, tuple)):
            asr_batch_count = len(input_value)
        else:
            input_array = np.asarray(input_value)
            asr_batch_count = input_array.shape[0] if input_array.ndim > 1 else 1
        result = original_inference(input_value, *args, **kwargs)

        if target_model is model.vad_model:
            state["total_speech_ms"] = sum(
                max(0, segment[1] - segment[0])
                for item in result
                for segment in (item.get("value") or [])
            )
            reporter.emit(8.0)
        elif target_model is model.model:
            state["processed_speech_ms"] += asr_duration
            total = max(state["total_speech_ms"], state["processed_speech_ms"], 1.0)
            ratio = min(1.0, state["processed_speech_ms"] / total)
            state["pending_percent"] = 8.0 + ratio * 82.0
            if mode == "standard":
                state["pending_speaker_calls"] += max(1, asr_batch_count)
            else:
                reporter.emit(state["pending_percent"])
        elif mode == "standard" and target_model is model.spk_model:
            state["pending_speaker_calls"] = max(0, state["pending_speaker_calls"] - 1)
            if state["pending_speaker_calls"] == 0:
                reporter.emit(state["pending_percent"])
        elif target_model is model.punc_model:
            reporter.emit(94.0)
        return result

    model.inference = inference_with_progress


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe a WAV file with local paraformer-zh.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("start_time")
    parser.add_argument("--mode", choices=("fast", "standard"), default="fast")
    args = parser.parse_args()
    reporter = ProgressReporter()
    reporter.emit(1.0)

    model, vad_model, punc_model, speaker_model = local_model_directories()

    model_options = dict(
        model=str(model),
        vad_model=str(vad_model),
        punc_model=str(punc_model),
        disable_update=True,
        disable_pbar=True,
    )
    if args.mode == "standard":
        model_options["spk_model"] = str(speaker_model)
    model = AutoModel(**model_options)
    reporter.emit(5.0)
    install_progress_bridge(model, reporter, args.mode)
    results = model.generate(
        input=str(args.input),
        batch_size_s=300,
        sentence_timestamp=args.mode == "fast",
    )
    if not results:
        raise RuntimeError("FunASR returned no transcribed text")
    reporter.emit(98.0)

    sentences = results[0].get("sentence_info") or []
    lines = [f"录音开始时间：{args.start_time}", ""]
    if sentences:
        for sentence in sentences:
            text = normalize_text(sentence.get("text") or sentence.get("sentence") or "")
            if not text:
                continue
            timestamp = relative_time(sentence.get("start", 0))
            if args.mode == "standard":
                speaker = int(sentence.get("spk", 0)) + 1
                lines.append(f"[{timestamp}] 说话人 {speaker}：{text}")
            else:
                lines.append(f"[{timestamp}] {text}")
    else:
        text = normalize_text(results[0].get("text", ""))
        if text:
            prefix = "说话人 1：" if args.mode == "standard" else ""
            lines.append(f"[00:00:00] {prefix}{text}")

    if len(lines) == 2:
        raise RuntimeError("FunASR returned no transcribed text")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    reporter.emit(100.0)


if __name__ == "__main__":
    main()
