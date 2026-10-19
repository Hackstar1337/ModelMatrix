#!/usr/bin/env python3
"""Record trimmed Hugging Face API answers as test fixtures.

Fixtures are plain JSON files read by HuggingFaceCheckTests through a fake
transport, so the normal test run needs no network. Re-run this script only
to refresh them.
"""
import json
import pathlib
import sys
import urllib.parse
import urllib.request

OUT = pathlib.Path(sys.argv[1])
API = "https://huggingface.co"
FIELDS = ["gguf", "library_name", "tags", "pipeline_tag", "gated", "private", "sha", "cardData",
          "downloads", "likes", "safetensors", "config", "baseModels", "lastModified"]
LIST_FIELDS = ["downloads", "likes", "tags", "library_name", "pipeline_tag", "gated"]

REPOS = [
    "bartowski/Qwen2.5-7B-Instruct-GGUF",
    "bartowski/Qwen2.5-72B-Instruct-GGUF",
    "ggml-org/gemma-3-4b-it-GGUF",
    "unsloth/Qwen3-30B-A3B-GGUF",
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "Qwen/Qwen2.5-7B-Instruct",
    "Qwen/Qwen2.5-7B-Instruct-AWQ",
    "mlc-ai/Llama-3-8B-Instruct-q4f16_1-MLC",
    "openai/whisper-large-v3",
    "stabilityai/stable-diffusion-xl-base-1.0",
    "meta-llama/Llama-3.1-8B-Instruct",
]
CHILDREN = ["Qwen/Qwen2.5-7B-Instruct", "meta-llama/Meta-Llama-3-8B-Instruct", "meta-llama/Llama-3.1-8B-Instruct"]
CONFIGS = ["mlx-community/Qwen2.5-7B-Instruct-4bit"]


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "ModelMatrix-fixtures"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def slug(text):
    return text.replace("/", "__").replace(":", "_")


def trim_info(info):
    keep = {k: info[k] for k in ["id", "sha", "gated", "private", "library_name", "pipeline_tag", "tags",
                                 "downloads", "likes", "lastModified"] if k in info}
    card = info.get("cardData") or {}
    keep["cardData"] = {k: card[k] for k in ["license", "license_name", "base_model", "base_model_relation",
                                             "pipeline_tag", "library_name"] if k in card}
    if "safetensors" in info:
        keep["safetensors"] = {k: info["safetensors"][k] for k in ["parameters", "total"] if k in info["safetensors"]}
    if "config" in info:
        keep["config"] = {k: info["config"][k] for k in ["model_type", "architectures", "quantization_config"]
                          if k in info["config"]}
    if "gguf" in info:
        keep["gguf"] = {k: v for k, v in info["gguf"].items() if k not in ("chat_template", "bos_token", "eos_token")}
    if "baseModels" in info:
        keep["baseModels"] = info["baseModels"]
    return keep


def trim_tree(entries):
    out = []
    for e in entries:
        item = {"type": e["type"], "path": e["path"], "size": e.get("size", 0)}
        if e.get("lfs"):
            item["lfs"] = {"oid": e["lfs"].get("oid"), "size": e["lfs"].get("size")}
        out.append(item)
    return out


def trim_list(items):
    return [{k: i[k] for k in ["id", "downloads", "likes", "gated", "library_name", "pipeline_tag"] if k in i}
            for i in items]


def models(filters, search=None, author=None, limit=20):
    query = [("filter", f) for f in filters]
    if search:
        query.append(("search", search))
    if author:
        query.append(("author", author))
    query += [("sort", "downloads"), ("direction", "-1"), ("limit", str(limit))]
    query += [("expand[]", f) for f in LIST_FIELDS]
    return trim_list(get(API + "/api/models?" + urllib.parse.urlencode(query)))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for repo in REPOS:
        query = urllib.parse.urlencode([("expand[]", f) for f in FIELDS])
        info = get(f"{API}/api/models/{repo}?{query}")
        (OUT / f"info__{slug(repo)}.json").write_text(json.dumps(trim_info(info), indent=1, sort_keys=True))
        tree = get(f"{API}/api/models/{repo}/tree/main?recursive=true")
        (OUT / f"tree__{slug(repo)}.json").write_text(json.dumps(trim_tree(tree), indent=1))
        print("recorded", repo, len(tree), "files")
    for base in CHILDREN:
        for fmt in ["gguf", "mlx"]:
            items = models([f"base_model:quantized:{base}", fmt])
            (OUT / f"children__{slug(base)}__{fmt}.json").write_text(json.dumps(items, indent=1))
    for repo in CONFIGS:
        config = get(f"{API}/{repo}/resolve/main/config.json")
        (OUT / f"config__{slug(repo)}.json").write_text(json.dumps(config, indent=1, sort_keys=True))
    siblings = models(["mlx"], search="Qwen2.5-7B-Instruct", author="mlx-community")
    (OUT / "search__mlx-community__Qwen2.5-7B-Instruct__mlx.json").write_text(json.dumps(siblings, indent=1))
    for fmt in ["gguf", "mlx"]:
        by_name = models([fmt], search="Qwen2.5-7B-Instruct")
        (OUT / f"search__Qwen2.5-7B-Instruct__{fmt}.json").write_text(json.dumps(by_name, indent=1))
    for fmt in ["gguf", "mlx"]:
        items = models([fmt], search="qwen2.5 coder 7b", limit=10)
        (OUT / f"search__qwen2.5 coder 7b__{fmt}.json".replace(" ", "_")).write_text(json.dumps(items, indent=1))
    print("done")


if __name__ == "__main__":
    main()
