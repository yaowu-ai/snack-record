#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

from funasr import AutoModel

MODEL_ID = "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
VAD_MODEL_ID = "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
PUNC_MODEL_ID = "iic/punc_ct-transformer_cn-en-common-vocab471067-large"
SPEAKER_MODEL_ID = "iic/speech_campplus_sv_zh-cn_16k-common"


def normalize_text(text: str) -> str:
    text = text.strip()
    return re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", text)


def relative_time(milliseconds: int) -> str:
    total_seconds = max(0, int(milliseconds)) // 1000
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe a WAV file with local paraformer-zh.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("start_time")
    args = parser.parse_args()

    model = AutoModel(
        model=MODEL_ID,
        vad_model=VAD_MODEL_ID,
        punc_model=PUNC_MODEL_ID,
        spk_model=SPEAKER_MODEL_ID,
        disable_update=True,
    )
    results = model.generate(input=str(args.input), batch_size_s=300)
    if not results:
        raise RuntimeError("FunASR returned no transcribed text")

    sentences = results[0].get("sentence_info") or []
    lines = [f"录音开始时间：{args.start_time}", ""]
    if sentences:
        for sentence in sentences:
            text = normalize_text(sentence.get("text", ""))
            if not text:
                continue
            speaker = int(sentence.get("spk", 0)) + 1
            timestamp = relative_time(sentence.get("start", 0))
            lines.append(f"[{timestamp}] 说话人 {speaker}：{text}")
    else:
        text = normalize_text(results[0].get("text", ""))
        if text:
            lines.append(f"[00:00:00] 说话人 1：{text}")

    if len(lines) == 2:
        raise RuntimeError("FunASR returned no transcribed text")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
