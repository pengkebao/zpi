#!/usr/bin/env python3
"""Generate src/ai/catalog.json from pi-ai's model catalog (pi 1.5.0).
Only chat models on the four wire protocols rpi implements, from providers
that authenticate via a plain API-key env var (matches pi env-api-keys.js)."""
import json, glob, os, sys

PI_DATA = os.path.expanduser(
    "~/.pi/agent/install/releases/1.5.0/node_modules/@earendil-works/pi-ai/dist/providers/data")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src/ai/catalog.json")

APIS = {"openai-completions", "anthropic-messages", "openai-responses", "google-generative-ai"}
ENV = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "google": "GEMINI_API_KEY",
    "xai": "XAI_API_KEY",
    "deepseek": "DEEPSEEK_API_KEY",
    "moonshotai": "MOONSHOT_API_KEY",
    "moonshotai-cn": "MOONSHOT_API_KEY",
    "zai": "ZAI_API_KEY",
    "zai-coding-cn": "ZAI_CODING_CN_API_KEY",
    "kimi-coding": "KIMI_API_KEY",
    "minimax": "MINIMAX_API_KEY",
    "minimax-cn": "MINIMAX_CN_API_KEY",
    "mistral": "MISTRAL_API_KEY",
    "groq": "GROQ_API_KEY",
    "together": "TOGETHER_API_KEY",
    "fireworks": "FIREWORKS_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
    "cerebras": "CEREBRAS_API_KEY",
    "nvidia": "NVIDIA_API_KEY",
    "baseten": "BASETEN_API_KEY",
    "ant-ling": "ANT_LING_API_KEY",
    "meta": "META_API_KEY",
    "xiaomi": "XIAOMI_API_KEY",
    "huggingface": "HF_TOKEN",
}
LEVELS = ["off", "low", "medium", "high", "xhigh", "max"]

providers = {}
for f in sorted(glob.glob(PI_DATA + "/*.json")):
    pid = os.path.basename(f)[:-5]
    if pid not in ENV:
        continue
    try:
        d = json.load(open(f))
    except Exception:
        continue
    models = []
    seen = set()
    for api, group in d.items():
        if api not in APIS or not isinstance(group, dict):
            continue
        for key, m in sorted(group.items()):
            if not key.startswith("chat:") or not isinstance(m, dict):
                continue
            mid = m.get("id")
            if not mid or (pid, mid) in seen:
                continue
            seen.add((pid, mid))
            cost = m.get("cost") or {}
            compat = m.get("compat") or {}
            tmap = m.get("thinkingLevelMap") or {}
            filtered_map = {}
            for lv in LEVELS:
                v = tmap.get(lv)
                # pi: value null = level unsupported; absent = pass through.
                # Keep only meaningful remappings (string values).
                if isinstance(v, str) and v != lv:
                    filtered_map[lv] = v
            entry = {
                "id": mid,
                "name": m.get("name", mid),
                "api": m.get("api", api),
                "baseUrl": m.get("baseUrl", ""),
                "reasoning": bool(m.get("reasoning", False)),
                "ctx": m.get("contextWindow", 128000),
                "max": m.get("maxTokens", 16384),
                "images": "image" in (m.get("input") or []),
            }
            if cost.get("input") is not None: entry["ci"] = cost["input"]
            if cost.get("output") is not None: entry["co"] = cost["output"]
            if cost.get("cacheRead") is not None: entry["cr"] = cost["cacheRead"]
            if cost.get("cacheWrite") is not None: entry["cw"] = cost["cacheWrite"]
            tf = compat.get("thinkingFormat")
            if tf: entry["tf"] = tf
            if filtered_map: entry["map"] = filtered_map
            models.append(entry)
    if not models:
        continue
    base = models[0].get("baseUrl", "")
    name = {"openai": "OpenAI", "anthropic": "Anthropic", "google": "Google",
            "xai": "xAI", "zai": "Z.ai", "zai-coding-cn": "Z.ai Coding CN",
            "deepseek": "DeepSeek", "moonshotai": "Moonshot AI",
            "moonshotai-cn": "Moonshot AI CN", "kimi-coding": "Kimi Coding",
            "minimax": "MiniMax", "minimax-cn": "MiniMax CN",
            "mistral": "Mistral", "groq": "Groq", "together": "Together",
            "fireworks": "Fireworks", "openrouter": "OpenRouter",
            "cerebras": "Cerebras", "nvidia": "NVIDIA", "baseten": "Baseten",
            "ant-ling": "AntLing", "meta": "Meta", "xiaomi": "Xiaomi",
            "huggingface": "HuggingFace"}.get(pid, pid)
    providers[pid] = {
        "id": pid, "name": name, "env": ENV[pid],
        "baseUrl": base,
        "defaultModel": models[0]["id"],
        "models": models,
    }

out = {"providers": sorted(providers.values(), key=lambda p: p["id"])}
total = sum(len(p["models"]) for p in out["providers"])
with open(OUT, "w") as f:
    json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
print(f"providers={len(out['providers'])} models={total} bytes={os.path.getsize(OUT)}")
